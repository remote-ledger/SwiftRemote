# Fixtures: a slice of the Remote Ledger's app API v1

Written by `tools/ledger_api_golden.py` from a built `site/app/v1` tree
(dataVersion `b7b18bba2dae`). Do not edit by hand; regenerate.

## What is a real file and what is cut down

Byte for byte what the ledger publishes:

- `manifest.json` and `brands.json` (all 4,902 brands).
- `b/<key>.m.json` and `b/<key>.k.json` for 28 brands, so that each
  `.m` file's `hash` still matches the SHA-256 of its `.k` file:
  `B2B.TEST`, `STRIM(AMINO)`, `BRENNAN`, `UNIDEN`, `AMCREST`, `VOLVO`, `SATEC`, `JIN LIPU`, `AS`, `TRICE`, `EVGO`, `VENTILYATOR`, `FRITZU`, `B&W`, `T+A`, `BOOTS`, `COMPACT`, `CYFROWY POLSAT`, `ЭРА`, `СМОТРЁШКА`, `ERA`, `Citilux`, `Natali Kovaltseva`, `APPLE`, `SKY DEUTSCHLAND`, `XIAOMI`, `KEF`, `DAEWOO`.

Cut down, because the whole of them is 4.2 MB and 73 KB and the fixtures should
stay near 1 MB:

- `s/<protocol>.json`, the signal shards of the ten protocols the app reads from
  the ledger. Each keeps its header (`p`, `ledger`, `carrierHz`,
  `carrierHzByLedger`, `minSends`, `play`) and only the codes the fixture brands
  hold plus the first five of the file, so every code a fixture brand lists has
  its signal:
  - `s/Denon.json`: 82 codes
  - `s/JVC.json`: 53 codes
  - `s/Pioneer.json`: 15 codes
  - `s/Proton.json`: 433 codes
  - `s/RCC2026.json`: 31 codes
  - `s/SONY12.json`: 12 codes
  - `s/SONY15.json`: 21 codes
  - `s/SONY20.json`: 67 codes
  - `s/Sharp.json`: 10 codes
  - `s/Thomson7.json`: 29 codes
- `power.json`: 95 rows, the 60 most popular and every row whose signal
  the cut-down shards still hold, in the file's order.

Because the shards and the power list are cut down, `manifest.json`'s
`dataVersion` (a hash over every file but the manifest) is not the hash of this
directory, and `power.rows` says more than `power.json` holds. Nothing here
recomputes it.

## golden.json

1144 answers of the app's old sqlite (`assets/db/swiftremote.sqlite` at 6aafd15)
to its own queries over these brands: the same SQL, run on the old database,
de-duplicated by (id, label, hexcode, protocol) and restricted to the keys the
ledger holds. `test/ledger_db_golden_test.dart` asks the new implementation the
same questions and compares count, a SHA-256 of the whole ordered answer, and
its first rows. Ties SQLite leaves unordered are written in the order of their
text. See the docstring of the generator.
