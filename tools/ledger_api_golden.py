#!/usr/bin/env python3
"""Regenerate test/fixtures/ledger_api: a small slice of the Remote Ledger's
app API, and the answers the app's old sqlite gave for the same questions.

The app used to answer its seven IrBlasterDb queries with SQL over a bundled
sqlite (assets/db/swiftremote.sqlite, built from the SQL dump the ledger's
importer started from). It now answers them from the ledger's static files
(https://remote-ledger.github.io/app/v1/). test/ledger_db_golden_test.dart
holds the new implementation to the old one's behaviour, and this script is
where the old behaviour is written down:

  1. It copies a handful of brands (and the manifest, brands.json, and the
     signal shards and power list cut down to what the tests use) from a built
     API tree into test/fixtures/ledger_api/.
  2. It runs the app's own SQL, character for character as it stood in
     lib/ir_finder/irblaster_db.dart at 6aafd15, on the old sqlite for a
     sample of queries over those brands, and writes what came back to
     golden.json beside the fixtures.

The old queries returned one row per (model, key). The new implementation
returns each key once, de-duplicated by (id, label, hexcode, protocol), so the
old rows are de-duplicated the same way here. Keys the ledger could not
represent are not in the API (the importer's IMPORT.md lists them), so the old
rows are restricted to the keys the API holds; that is the only other
difference, and it is the one the ledger's own tools/app_api_vs_sql.py checks
over the whole database.

SQLite leaves ties unordered (two keys of one remote whose labels differ only
in letter case, two models whose names differ only in letter case). The new
implementation orders them by their exact text, so tied rows are written here
in that order too.

Run it from the repository root:

    python3 tools/ledger_api_golden.py --api /path/to/site/app/v1 \\
        --old-db /path/to/swiftremote.sqlite

It reads the whole API tree (about 57 MB) to know which keys are held, and
takes under a minute. The sqlite is opened read-only. Python's sqlite3 folds
only ASCII letters in UPPER, NOCASE and LIKE, which is what the app's queries
assumed; an Android SQLite built with ICU would order a non-ASCII label
differently (the ledger's NOTES/app-api.md, D76, says the same).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import shutil
import sqlite3
import string
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "test" / "fixtures" / "ledger_api"

# Brands copied into the fixtures. Between them they cover every one of the 23
# database protocols (the ten the app reads from the ledger's signal, and the
# thirteen it decodes itself), brand names with lower-case letters and
# punctuation, two Cyrillic names, labels holding %, backslashes and non-ASCII
# letters, and one brand of a few thousand keys (DAEWOO) for paging.
BRANDS = [
    "B2B.TEST",  # RCA_38, Thomson7
    "STRIM(AMINO)",  # NECx2, REC80, Sharp, SONY12
    "BRENNAN",  # SONY12, SONY15, SONY20
    "UNIDEN",  # Denon
    "AMCREST",  # Pioneer
    "VOLVO",  # JVC
    "SATEC",  # Proton
    "JIN LIPU",  # RCC2026
    "AS",  # NEC
    "TRICE",  # NEC2
    "EVGO",  # NECx1, non-ASCII and backslash in labels
    "VENTILYATOR",  # F12_relaxed
    "FRITZU",  # RC5
    "B&W",  # RC6
    "T+A",  # RCC0082
    "BOOTS",  # RECS80
    "COMPACT",  # RECS80_L
    "CYFROWY POLSAT",  # Samsung36
    "ЭРА",  # Cyrillic, % in a label
    "СМОТРЁШКА",  # Cyrillic
    "ERA",  # % in a label
    "Citilux",  # mixed-case brand name
    "Natali Kovaltseva",  # mixed-case, % in a label
    "APPLE",  # backslash and non-ASCII in labels
    "SKY DEUTSCHLAND",  # non-ASCII labels
    "XIAOMI",
    "KEF",
    "DAEWOO",  # a few thousand keys, 2,286 models
]

# What the tests ask for. They are samples: the golden test is a regression
# guard for ordering, filtering and de-duplication, not a proof over every
# combination (tools/app_api_vs_sql.py in the ledger is that).
BRAND_SEARCHES = [None, "a", "SONY", "tv", "1", "é", "ЭР", "%", "_", " o gen ", "zzzz"]
PROTOCOL_ARGS = [
    None, "sony12", "RCA-38", "nec", "necx1", "Thomson7", "recs80_l", "pioneer",
    "unknown_proto", "rcc2026", "  ", "denon",
]
KEY_SEARCHES = [
    None, "power", "vol", "ch", "OK", "menu", " 1 ", "a", "é", "%", "_", "vol_", "\\",
    "2F", "a9", "zzzzz",
]
FETCH_PER_BRAND = 8
FETCH_PER_BRAND_BIG = 48
HEAD = 3

LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)
UPPER = str.maketrans(string.ascii_lowercase, string.ascii_uppercase)


def up(text: str) -> str:
    """SQLite's UPPER: ASCII letters only."""
    return text.translate(UPPER)


def nocase(text: str) -> str:
    """The sort key of COLLATE NOCASE: ASCII letters folded to lower case,
    compared as UTF-8, which is code point order."""
    return text.translate(LOWER)


def escape_field(text: str) -> str:
    return (
        text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
    )


def digest_rows(rows: list[list]) -> str:
    """sha256 over id, label, protocol and hexcode of each row, as the Dart
    test computes it (test/ledger_db_golden_test.dart, `digestRows`)."""
    lines = [
        "\t".join([str(r[0]), escape_field(r[1]), escape_field(r[2]), escape_field(r[3])])
        for r in rows
    ]
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def digest_strings(values: list[str]) -> str:
    return hashlib.sha256("\n".join(escape_field(v) for v in values).encode("utf-8")).hexdigest()


def protocol_key(text: str) -> str:
    """IrBlasterDb._protocolKey: trimmed, lower-cased, non-alphanumerics gone."""
    return re.sub(r"[^a-z0-9]+", "", text.strip().lower())


def escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


class Api:
    """The built API tree: what the ledger holds."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.manifest = json.loads((root / "manifest.json").read_text("utf-8"))
        self.protocols = [p["db"] for p in self.manifest["protocols"]]
        self.brands = json.loads((root / "brands.json").read_text("utf-8"))
        self.brand_names = {b[0] for b in self.brands}
        self.brand_key = {b[0]: b[1] for b in self.brands}
        # id -> {(label, hexcode, protocol)}, and the protocols each brand holds
        self.held: dict[int, set[tuple[str, str, str]]] = {}
        self.brand_protocols: dict[str, set[str]] = {}
        for name, key, _mask in self.brands:
            keys = json.loads((root / "b" / f"{key}.k.json").read_text("utf-8"))
            protocols: set[str] = set()
            for remote_id, rows in keys["r"]:
                bucket = self.held.setdefault(remote_id, set())
                for label, proto_idx, hexcode in rows:
                    bucket.add((label, hexcode, self.protocols[proto_idx]))
                    protocols.add(self.protocols[proto_idx])
            self.brand_protocols[name] = protocols

    def holds(self, remote_id: int, label: str, hexcode: str, protocol: str) -> bool:
        return (label, hexcode, protocol) in self.held.get(remote_id, ())


class OldDb:
    """The old sqlite, asked the questions the old IrBlasterDb asked."""

    RANK_CASE = """
 CASE
 WHEN UPPER(k.label) LIKE '%POWER%' OR UPPER(k.label) IN ('PWR','POWER','ON','OFF') THEN 0
 WHEN UPPER(k.label) LIKE '%MUTE%' OR UPPER(k.label) = 'MUTE' THEN 1
 WHEN UPPER(k.label) LIKE 'VOL%' OR UPPER(k.label) LIKE '%VOLUME%' THEN 2
 WHEN UPPER(k.label) LIKE 'CH%' OR UPPER(k.label) LIKE '%CHANNEL%' THEN 3
 WHEN UPPER(k.label) IN ('OK','ENTER','MENU','HOME','BACK','UP','DOWN','LEFT','RIGHT') THEN 4
 ELSE 9
 END"""

    def __init__(self, path: Path, api: Api) -> None:
        self.con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.api = api
        # Distinct protocol spellings, as IrBlasterDb._ensureProtocolMapLoaded
        self.canonical: dict[str, str] = {}
        for (value,) in self.con.execute("SELECT DISTINCT protocol FROM keys WHERE protocol IS NOT NULL"):
            self.canonical.setdefault(protocol_key(value), value)

    def protocol_clause(self, column: str, selected: str | None):
        """_resolveProtocolFilter + _appendProtocolWhere."""
        if selected is None or not selected.strip():
            return None
        key = protocol_key(selected.strip())
        if not key:
            return None
        canonical = self.canonical.get(key)
        if canonical is not None:
            return (f"{column} = ?", canonical)
        return (f"lower(replace(replace(replace({column},'-',''),'_',''),' ','')) = ?", key)

    # -- brands and models --------------------------------------------------

    def brands(self, search: str | None, protocol: str | None) -> list[str]:
        q = None if search is None or not search.strip() else search.strip()
        where, args = [], []
        clause = self.protocol_clause("k.protocol", protocol)
        if clause:
            where.append(clause[0])
            args.append(clause[1])
        if q is not None:
            where.append("m.brand LIKE ? ESCAPE '\\'")
            args.append(f"%{escape_like(q)}%")
        sql = f"""
      SELECT DISTINCT m.brand AS name
      FROM models m
      JOIN keys k ON k.id = m.id
      {'WHERE ' + ' AND '.join(where) if where else ''}
      ORDER BY name COLLATE NOCASE ASC
    """
        names = [r[0] for r in self.con.execute(sql, args)]
        held_protocols = self.api.brand_protocols
        wanted = self.canonical.get(protocol_key(protocol.strip())) if clause and protocol else None
        out = []
        for name in names:
            if name not in self.api.brand_names:
                continue  # a brand only unrepresentable keys list
            if clause is not None:
                if wanted is None:
                    continue
                if wanted not in held_protocols.get(name, ()):
                    continue
            out.append(name)
        return sorted(out, key=lambda n: (nocase(n), n))

    def model_ids(self, brand: str) -> dict[str, list[int]]:
        ids: dict[str, list[int]] = {}
        for model, remote_id in self.con.execute(
            "SELECT model, id FROM models WHERE brand = ?", (brand,)
        ):
            ids.setdefault(model, []).append(remote_id)
        return ids

    def models(self, brand: str, search: str | None, protocol: str | None) -> list[str]:
        q = None if search is None or not search.strip() else search.strip()
        clause = self.protocol_clause("k.protocol", protocol)
        if clause is None:
            where, args = ["brand = ?"], [brand]
            if q is not None:
                where.append("model LIKE ? ESCAPE '\\'")
                args.append(f"%{escape_like(q)}%")
            sql = f"SELECT DISTINCT model FROM models WHERE {' AND '.join(where)} ORDER BY model COLLATE NOCASE ASC"
        else:
            where, args = ["m.brand = ?", clause[0]], [brand, clause[1]]
            if q is not None:
                where.append("m.model LIKE ? ESCAPE '\\'")
                args.append(f"%{escape_like(q)}%")
            sql = f"""
      SELECT DISTINCT m.model AS model
      FROM models m
      JOIN keys k ON k.id = m.id
      WHERE {' AND '.join(where)}
      ORDER BY model COLLATE NOCASE ASC
    """
        models = [r[0] for r in self.con.execute(sql, args)]
        ids = self.model_ids(brand)
        wanted = self.canonical.get(protocol_key(protocol.strip())) if clause and protocol else None
        out = []
        for model in models:
            held = [k for i in ids.get(model, ()) for k in self.api.held.get(i, ())]
            if clause is not None:
                held = [k for k in held if k[2] == wanted]
            if held:
                out.append(model)
        return sorted(out, key=lambda m: (nocase(m), m))

    def protocols(self, brand: str, model: str | None) -> list[str]:
        ids = self.model_ids(brand)
        chosen = [i for m, lst in ids.items() if model is None or m == model for i in lst]
        found = {k[2] for i in chosen for k in self.api.held.get(i, ())}
        return sorted(found, key=up)

    # -- keys ---------------------------------------------------------------

    def keys(
        self,
        brand: str,
        model: str | None,
        protocol: str | None,
        quick: bool,
        prefix: str | None,
        search: str | None,
    ) -> list[list]:
        """fetchCandidateKeys without the paging: every row, in order,
        de-duplicated, restricted to the held keys, ties in text order."""
        m = None if model is None or not model.strip() else model.strip()
        p = (
            None
            if prefix is None or not prefix.strip()
            else re.sub(r"\s+", "", prefix).upper()
        )
        where, args = ["m.brand = ?"], [brand]
        if m is not None:
            where.append("m.model = ?")
            args.append(m)
        clause = self.protocol_clause("k.protocol", protocol)
        if clause:
            where.append(clause[0])
            args.append(clause[1])
        if p is not None:
            where.append("UPPER(k.hexcode) LIKE ?")
            args.append(f"{p}%")
        q = None if search is None or not search.strip() else escape_like(search.strip())
        if q is not None:
            where.append("(UPPER(k.label) LIKE UPPER(?) ESCAPE '\\' OR UPPER(k.hexcode) LIKE UPPER(?))")
            args.append(f"%{q}%")
            args.append(f"%{q.upper()}%")
        # quickWinsFirst orders by the CASE first; without it the CASE is not
        # in the ORDER BY, and the column is only there to be read back.
        rank = self.RANK_CASE if quick else "0"
        order = (rank + " ASC, " if quick else "") + (
            "UPPER(k.label) ASC, UPPER(k.protocol) ASC, UPPER(k.hexcode) ASC, k.id ASC"
        )
        sql = f"""
 SELECT k.id, k.label, k.protocol, k.hexcode, {rank} AS rank
 FROM models m
 JOIN keys k ON k.id = m.id
 WHERE {' AND '.join(where)}
 ORDER BY {order}
"""
        seen: set[tuple[int, str, str, str]] = set()
        rows: list[tuple] = []
        for remote_id, label, proto, hexcode, r in self.con.execute(sql, args):
            ident = (remote_id, label, hexcode, proto)
            if ident in seen:
                continue
            seen.add(ident)
            if not self.api.holds(remote_id, label, hexcode, proto):
                continue
            rows.append((r, up(label), up(proto), up(hexcode), remote_id, label, proto, hexcode))
        # Ties: rows SQLite orders arbitrarily are put in the order of their text.
        out: list[list] = []
        i = 0
        while i < len(rows):
            j = i
            while j < len(rows) and rows[j][:5] == rows[i][:5]:
                j += 1
            group = sorted(rows[i:j], key=lambda t: (t[5], t[6], t[7]))
            out.extend([[g[4], g[5], g[6], g[7]] for g in group])
            i = j
        return out


def pick_brand_files(api: Api, out: Path) -> list[str]:
    (out / "b").mkdir(parents=True, exist_ok=True)
    for name in BRANDS:
        if name not in api.brand_key:
            raise SystemExit(f"brand {name!r} is not in the API at {api.root}")
        key = api.brand_key[name]
        for suffix in ("m", "k"):
            shutil.copyfile(api.root / "b" / f"{key}.{suffix}.json", out / "b" / f"{key}.{suffix}.json")
    return BRANDS


def write_shards(api: Api, out: Path) -> dict[str, int]:
    """The ten signal shards, cut down to the codes the fixture brands hold
    (and a few more, so that a code the tests do not name is still there)."""
    (out / "s").mkdir(parents=True, exist_ok=True)
    used: dict[str, set[str]] = {}
    for name in BRANDS:
        keys = json.loads((api.root / "b" / f"{api.brand_key[name]}.k.json").read_text("utf-8"))
        for _remote_id, rows in keys["r"]:
            for _label, proto_idx, hexcode in rows:
                used.setdefault(api.protocols[proto_idx], set()).add(hexcode)
    kept: dict[str, int] = {}
    for protocol in (p["db"] for p in api.manifest["protocols"] if p["appReadingDiffers"]):
        shard = json.loads((api.root / "s" / f"{protocol}.json").read_text("utf-8"))
        signals = shard["s"]
        keep = {h for h in signals if h in used.get(protocol, ())}
        for h in list(signals)[:5]:
            keep.add(h)
        shard["s"] = {h: signals[h] for h in sorted(keep)}
        text = json.dumps(shard, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        (out / "s" / f"{protocol}.json").write_text(text, "utf-8")
        kept[protocol] = len(shard["s"])
    return kept


def write_power(api: Api, out: Path, kept: dict[str, int]) -> int:
    """power.json: the 60 most popular rows, and every row whose signal the
    cut-down shards still hold, in the file's order."""
    power = json.loads((api.root / "power.json").read_text("utf-8"))
    shards = {
        p: json.loads((out / "s" / f"{p}.json").read_text("utf-8"))["s"]
        for p in kept
    }
    rows = []
    for index, row in enumerate(power):
        proto = api.protocols[row[0]]
        if index < 60 or (proto in shards and row[1] in shards[proto]):
            rows.append(row)
    text = json.dumps(rows, ensure_ascii=False, separators=(",", ":")) + "\n"
    (out / "power.json").write_text(text, "utf-8")
    return len(rows)


def build_cases(api: Api, old: OldDb, rng: random.Random) -> list[dict]:
    cases: list[dict] = []

    def strings_case(fn: str, args: dict, values: list[str]) -> None:
        cases.append(
            {"fn": fn, "args": args, "count": len(values), "sha": digest_strings(values), "head": values[:HEAD]}
        )

    # listBrands: the whole list, so every protocol bit and the NOCASE order
    # are exercised over all 4,902 brands.
    for search in BRAND_SEARCHES:
        for protocol in PROTOCOL_ARGS:
            if search is not None and protocol is not None and rng.random() < 0.7:
                continue
            names = old.brands(search, protocol)
            strings_case("listBrands", {"search": search, "protocol": protocol}, names)

    for brand in BRANDS:
        big = brand == "DAEWOO"
        models = old.models(brand, None, None)
        protocols_of_brand = old.protocols(brand, None)
        strings_case("listProtocolsForBrand", {"brand": brand}, protocols_of_brand)

        # listModelsDistinct
        for search in [None, "a", "é", "%", "  x  "]:
            strings_case(
                "listModelsDistinct",
                {"brand": brand, "search": search, "protocol": None},
                old.models(brand, search, None),
            )
        for protocol in protocols_of_brand:
            strings_case(
                "listModelsDistinct",
                {"brand": brand, "search": None, "protocol": protocol},
                old.models(brand, None, protocol),
            )
            if protocol == protocols_of_brand[0]:
                strings_case(
                    "listModelsDistinct",
                    {"brand": brand, "search": "a", "protocol": protocol.lower()},
                    old.models(brand, "a", protocol.lower()),
                )

        # Models to ask the key queries about: first, last, the one with the
        # most keys, and some at random.
        ids = old.model_ids(brand)
        # A model name with spaces around it cannot be asked for: the app trims
        # what it is given before it compares.
        models = [m for m in models if m == m.strip()]
        listed = set(models)
        counts = {m: sum(len(old.api.held.get(i, ())) for i in lst) for m, lst in ids.items() if m in listed}
        chosen: list[str | None] = [None]
        if models:
            chosen += [models[0], models[-1], max(counts, key=lambda m: (counts[m], m))]
            chosen += rng.sample(models, min(len(models), 6 if big else 1))
        seen_models: list[str | None] = []
        for m in chosen:
            if m not in seen_models:
                seen_models.append(m)

        for m in seen_models:
            if m is not None:
                strings_case("listProtocolsFor", {"brand": brand, "model": m}, old.protocols(brand, m))
        budget = FETCH_PER_BRAND_BIG if big else FETCH_PER_BRAND
        combos = []
        for m in seen_models:
            protos = [None] + (old.protocols(brand, m) if m is not None else protocols_of_brand)
            for protocol in protos:
                for quick in (True, False):
                    combos.append((m, protocol, quick))
        rng.shuffle(combos)
        for m, protocol, quick in combos[:budget]:
            # Spelling of the protocol as the screens pass it: an app protocol id.
            spelled = None if protocol is None else rng.choice([protocol, protocol.lower(), protocol.upper()])
            base = old.keys(brand, m, spelled, quick, None, None)
            variants: list[tuple[str | None, str | None]] = [(None, None)]
            if base:
                head_hex = base[0][3]
                variants.append((head_hex[: rng.choice([1, 2, 3])], None))
                variants.append((" " + head_hex[:2].lower() + " ", rng.choice(KEY_SEARCHES)))
            else:
                variants.append(("A", None))
            for prefix, search in variants:
                rows = old.keys(brand, m, spelled, quick, prefix, search)
                cases.append(
                    {
                        "fn": "fetchCandidateKeys",
                        "args": {
                            "brand": brand,
                            "model": m,
                            "protocol": spelled,
                            "quickWinsFirst": quick,
                            "hexPrefix": prefix,
                            "search": search,
                        },
                        "count": len(rows),
                        "sha": digest_rows(rows),
                        "head": rows[:HEAD],
                    }
                )
    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api", required=True, type=Path, help="a built app API tree (site/app/v1)")
    parser.add_argument("--old-db", required=True, type=Path, help="the old swiftremote.sqlite")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    api = Api(args.api)
    out: Path = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    shutil.copyfile(args.api / "manifest.json", out / "manifest.json")
    shutil.copyfile(args.api / "brands.json", out / "brands.json")
    pick_brand_files(api, out)
    kept = write_shards(api, out)
    power_rows = write_power(api, out, kept)

    old = OldDb(args.old_db, api)
    rng = random.Random(20261003)
    cases = build_cases(api, old, rng)
    golden = {
        "about": "Answers of the old sqlite IrBlasterDb to a sample of queries, de-duplicated and "
        "restricted to the keys the ledger holds. Written by tools/ledger_api_golden.py.",
        "dataVersion": api.manifest["dataVersion"],
        "cases": cases,
    }
    (out / "golden.json").write_text(
        json.dumps(golden, ensure_ascii=False, separators=(",", ":")) + "\n", "utf-8"
    )
    (out / "README.md").write_text(readme(api, kept, power_rows, len(cases)), "utf-8")
    total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"{len(cases)} cases, {len(BRANDS)} brands, shards {kept}, power rows {power_rows}, {total} bytes")


def readme(api: Api, kept: dict[str, int], power_rows: int, cases: int) -> str:
    shard_lines = "\n".join(f"  - `s/{p}.json`: {n} codes" for p, n in sorted(kept.items()))
    brand_lines = ", ".join(f"`{b}`" for b in BRANDS)
    return f"""# Fixtures: a slice of the Remote Ledger's app API v1

Written by `tools/ledger_api_golden.py` from a built `site/app/v1` tree
(dataVersion `{api.manifest['dataVersion']}`). Do not edit by hand; regenerate.

## What is a real file and what is cut down

Byte for byte what the ledger publishes:

- `manifest.json` and `brands.json` (all 4,902 brands).
- `b/<key>.m.json` and `b/<key>.k.json` for {len(BRANDS)} brands, so that each
  `.m` file's `hash` still matches the SHA-256 of its `.k` file:
  {brand_lines}.

Cut down, because the whole of them is 4.2 MB and 73 KB and the fixtures should
stay near 1 MB:

- `s/<protocol>.json`, the signal shards of the ten protocols the app reads from
  the ledger. Each keeps its header (`p`, `ledger`, `carrierHz`,
  `carrierHzByLedger`, `minSends`, `play`) and only the codes the fixture brands
  hold plus the first five of the file, so every code a fixture brand lists has
  its signal:
{shard_lines}
- `power.json`: {power_rows} rows, the 60 most popular and every row whose signal
  the cut-down shards still hold, in the file's order.

Because the shards and the power list are cut down, `manifest.json`'s
`dataVersion` (a hash over every file but the manifest) is not the hash of this
directory, and `power.rows` says more than `power.json` holds. Nothing here
recomputes it.

## golden.json

{cases} answers of the app's old sqlite (`assets/db/swiftremote.sqlite` at 6aafd15)
to its own queries over these brands: the same SQL, run on the old database,
de-duplicated by (id, label, hexcode, protocol) and restricted to the keys the
ledger holds. `test/ledger_db_golden_test.dart` asks the new implementation the
same questions and compares count, a SHA-256 of the whole ordered answer, and
its first rows. Ties SQLite leaves unordered are written in the order of their
text. See the docstring of the generator.
"""


if __name__ == "__main__":
    main()
