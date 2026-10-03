import 'dart:convert';
import 'dart:typed_data';

import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/sqlite_text.dart';
import 'package:swiftremote/utils/ledger_signal.dart';

/// The version of the app API this build reads (`manifest.schemaVersion`).
/// The files live under `/app/v1/` and the ledger keeps v1 stable; a manifest
/// that says anything else is refused rather than guessed at.
const int kLedgerApiSchemaVersion = 1;

/// How one key press of a protocol is played from its Pronto signal:
/// the intro once, then the repeat sequence [repeatPasses] times
/// (`play` in a signal shard and in the manifest).
class LedgerPlay {
  const LedgerPlay({
    required this.repeatPasses,
    required this.helperRepeatPasses,
    required this.introEmpty,
    required this.rule,
  });

  /// Passes of the repeat sequence after the intro, for one press. This is
  /// the number the app plays.
  final int repeatPasses;

  /// What the app's helper for Remote Ledger files plays for the same code
  /// (`minSends` based). Differs from [repeatPasses] for Sharp and Denon.
  final int helperRepeatPasses;
  final bool introEmpty;

  /// `ledger` (the helper's rule) or `full-signal` (the intro and the repeat
  /// sequence, which hold the frames of a Sharp or Denon press).
  final String rule;

  static LedgerPlay? fromJson(dynamic json) {
    if (json is! Map) return null;
    final dynamic passes = json['repeatPasses'];
    if (passes is! int || passes < 0) return null;
    final dynamic helper = json['helperRepeatPasses'];
    final dynamic empty = json['introEmpty'];
    final dynamic rule = json['rule'];
    return LedgerPlay(
      repeatPasses: passes,
      helperRepeatPasses: helper is int ? helper : passes,
      introEmpty: empty is bool ? empty : false,
      rule: rule is String ? rule : 'ledger',
    );
  }
}

/// One of the database's protocols, as the manifest lists it. The position in
/// the manifest is the bit this protocol has in every `protoMask`, and the
/// index every key row of a brand file carries.
class LedgerProtocol {
  const LedgerProtocol({
    required this.index,
    required this.db,
    required this.ledger,
    required this.minSends,
    required this.carrierHz,
    required this.carrierHzByLedger,
    required this.appReadingDiffers,
    required this.play,
  });

  final int index;

  /// The database's name for it (`SONY12`, `RCA_38`); what the old tables
  /// stored in `keys.protocol`.
  final String db;

  /// The ledger's protocol names compiled for it.
  final List<String> ledger;
  final int? minSends;

  /// The carrier, or null where the ledger's protocols for it disagree (only
  /// `REC80`).
  final int? carrierHz;
  final Map<String, int> carrierHzByLedger;

  /// Whether the app's own hex decoding reads this protocol's database codes
  /// differently from the wire. Where true the app plays the ledger's compiled
  /// signal (`s/<db>.json`) and never its own decoder.
  final bool appReadingDiffers;
  final LedgerPlay? play;

  /// The normalised key the app compares protocols by (`rca38`).
  String get key => protocolKey(db);

  static LedgerProtocol fromJson(int index, dynamic json) {
    if (json is! Map || json['db'] is! String) {
      throw const FormatException('A protocol of the manifest has no name.');
    }
    final dynamic ledger = json['ledger'];
    final dynamic byLedger = json['carrierHzByLedger'];
    return LedgerProtocol(
      index: index,
      db: json['db'] as String,
      ledger: ledger is List
          ? ledger.whereType<String>().toList(growable: false)
          : const <String>[],
      minSends: json['minSends'] is int ? json['minSends'] as int : null,
      carrierHz: json['carrierHz'] is int ? json['carrierHz'] as int : null,
      carrierHzByLedger: byLedger is Map
          ? <String, int>{
              for (final MapEntry<dynamic, dynamic> e in byLedger.entries)
                if (e.key is String && e.value is int)
                  e.key as String: e.value as int,
            }
          : const <String, int>{},
      appReadingDiffers: json['appReadingDiffers'] == true,
      play: LedgerPlay.fromJson(json['play']),
    );
  }
}

/// `manifest.json`: the version, the protocols, where everything is.
class LedgerManifest {
  const LedgerManifest({
    required this.schemaVersion,
    required this.dataVersion,
    required this.protocols,
    required this.counts,
    required this.paths,
  });

  final int schemaVersion;

  /// A hash over every file of the API but the manifest. Any change anywhere
  /// changes it, so it says "something changed", not what.
  final String dataVersion;
  final List<LedgerProtocol> protocols;
  final Map<String, int> counts;
  final Map<String, String> paths;

  static const Map<String, String> _defaultPaths = <String, String>{
    'brands': 'brands.json',
    'brandModels': 'b/{key}.m.json',
    'brandKeys': 'b/{key}.k.json',
    'signals': 's/{db}.json',
    'power': 'power.json',
  };

  String get brandsPath => paths['brands'] ?? _defaultPaths['brands']!;
  String get powerPath => paths['power'] ?? _defaultPaths['power']!;

  String brandModelsPath(String key) =>
      (paths['brandModels'] ?? _defaultPaths['brandModels']!)
          .replaceAll('{key}', key);
  String brandKeysPath(String key) =>
      (paths['brandKeys'] ?? _defaultPaths['brandKeys']!)
          .replaceAll('{key}', key);
  String signalsPath(String db) =>
      (paths['signals'] ?? _defaultPaths['signals']!).replaceAll('{db}', db);

  LedgerProtocol? protocolByDb(String db) {
    for (final LedgerProtocol p in protocols) {
      if (p.db == db) return p;
    }
    return null;
  }

  /// The protocol the app's own spelling names (`rca_38`, `RCA-38`), or null.
  LedgerProtocol? protocolByKey(String key) {
    for (final LedgerProtocol p in protocols) {
      if (p.key == key) return p;
    }
    return null;
  }

  /// Parses [json]. Throws [LedgerDbUnavailable] (unsupportedVersion) for a
  /// schema this build does not read, and [FormatException] for a manifest
  /// that is not one.
  factory LedgerManifest.fromJson(dynamic json) {
    if (json is! Map) {
      throw const FormatException('The manifest is not an object.');
    }
    final dynamic version = json['schemaVersion'];
    if (version != kLedgerApiSchemaVersion) {
      throw LedgerDbUnavailable(
        LedgerDbFailure.unsupportedVersion,
        'The IR code database has schema version $version; this version of '
        'the app reads version $kLedgerApiSchemaVersion.',
      );
    }
    final dynamic dataVersion = json['dataVersion'];
    if (dataVersion is! String || dataVersion.isEmpty) {
      throw const FormatException('The manifest has no dataVersion.');
    }
    final dynamic protocols = json['protocols'];
    if (protocols is! List || protocols.isEmpty) {
      throw const FormatException('The manifest lists no protocols.');
    }
    final dynamic counts = json['counts'];
    final dynamic paths = json['paths'];
    return LedgerManifest(
      schemaVersion: version as int,
      dataVersion: dataVersion,
      protocols: <LedgerProtocol>[
        for (int i = 0; i < protocols.length; i++)
          LedgerProtocol.fromJson(i, protocols[i]),
      ],
      counts: counts is Map
          ? <String, int>{
              for (final MapEntry<dynamic, dynamic> e in counts.entries)
                if (e.key is String && e.value is int)
                  e.key as String: e.value as int,
            }
          : const <String, int>{},
      paths: paths is Map
          ? <String, String>{
              for (final MapEntry<dynamic, dynamic> e in paths.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : const <String, String>{},
    );
  }

  static LedgerManifest parse(Uint8List bytes) =>
      LedgerManifest.fromJson(jsonDecode(utf8.decode(bytes)));
}

/// One row of `brands.json`.
class LedgerBrand {
  const LedgerBrand({
    required this.name,
    required this.key,
    required this.protoMask,
  });

  /// The brand as the old `models.brand` spelled it.
  final String name;

  /// What names the brand's files: the first ten hex digits of the SHA-1 of
  /// the name.
  final String key;

  /// Bit `i` is set when a key of the manifest's protocol `i` exists.
  final int protoMask;

  bool hasProtocol(int index) => (protoMask >> index) & 1 == 1;
}

/// `brands.json`, already in `COLLATE NOCASE` order of the name.
List<LedgerBrand> parseBrands(Uint8List bytes) {
  final dynamic json = jsonDecode(utf8.decode(bytes));
  if (json is! List) {
    throw const FormatException('brands.json is not a list.');
  }
  final List<LedgerBrand> brands = <LedgerBrand>[];
  for (final dynamic row in json) {
    if (row is! List ||
        row.length < 3 ||
        row[0] is! String ||
        row[1] is! String ||
        row[2] is! int) {
      throw const FormatException('A brand row of brands.json is malformed.');
    }
    brands.add(LedgerBrand(
      name: row[0] as String,
      key: row[1] as String,
      protoMask: row[2] as int,
    ));
  }
  return brands;
}

/// One model of a brand and the remote ids ([ids] indexes into
/// [LedgerBrandModels.ids]) its keys come from.
class LedgerModel {
  const LedgerModel({required this.name, required this.idIndexes});
  final String name;
  final List<int> idIndexes;
}

/// `b/<key>.m.json`: a brand's models and remote ids.
class LedgerBrandModels {
  LedgerBrandModels({
    required this.brand,
    required this.hash,
    required this.ids,
    required this.idMasks,
    required this.idKeyCounts,
    required this.models,
  });

  final String brand;

  /// The first six hex digits of the SHA-256 of the brand's `.k.json`: what
  /// that file must hash to, and what changes when the brand's keys do.
  final String hash;
  final List<int> ids;
  final List<int> idMasks;
  final List<int> idKeyCounts;

  /// In `COLLATE NOCASE` order of the name.
  final List<LedgerModel> models;

  Map<String, LedgerModel>? _byName;

  LedgerModel? model(String name) {
    final Map<String, LedgerModel> index = _byName ??= <String, LedgerModel>{
      for (final LedgerModel m in models) m.name: m,
    };
    return index[name];
  }

  Map<int, String>? _firstModelOfId;

  /// The first model, in the list's order, that draws on remote [id]. A
  /// listing of a whole brand shows each key once, under this model.
  String? firstModelOfId(int id) {
    final Map<int, String> index = _firstModelOfId ??= () {
      final Map<int, String> found = <int, String>{};
      for (final LedgerModel m in models) {
        for (final int i in m.idIndexes) {
          if (i < 0 || i >= ids.length) continue;
          found.putIfAbsent(ids[i], () => m.name);
        }
      }
      return found;
    }();
    return index[id];
  }

  /// The OR of the protocol masks of every id of the brand, or of one model.
  int maskOf(Iterable<int> idIndexes) {
    int mask = 0;
    for (final int i in idIndexes) {
      if (i >= 0 && i < idMasks.length) mask |= idMasks[i];
    }
    return mask;
  }

  static LedgerBrandModels parse(Uint8List bytes) {
    final dynamic json = jsonDecode(utf8.decode(bytes));
    if (json is! Map ||
        json['brand'] is! String ||
        json['hash'] is! String ||
        json['ids'] is! List ||
        json['models'] is! List) {
      throw const FormatException('A brand model file is malformed.');
    }
    final List<dynamic> idRows = json['ids'] as List<dynamic>;
    final List<int> ids = <int>[];
    final List<int> masks = <int>[];
    final List<int> counts = <int>[];
    for (final dynamic row in idRows) {
      if (row is! List || row.length < 3 || row.any((dynamic v) => v is! int)) {
        throw const FormatException('An id row of a brand file is malformed.');
      }
      ids.add(row[0] as int);
      masks.add(row[1] as int);
      counts.add(row[2] as int);
    }
    final List<LedgerModel> models = <LedgerModel>[];
    for (final dynamic row in json['models'] as List<dynamic>) {
      if (row is! List ||
          row.length < 2 ||
          row[0] is! String ||
          row[1] is! List) {
        throw const FormatException(
            'A model row of a brand file is malformed.');
      }
      models.add(LedgerModel(
        name: row[0] as String,
        idIndexes: (row[1] as List<dynamic>).whereType<int>().toList(
              growable: false,
            ),
      ));
    }
    return LedgerBrandModels(
      brand: json['brand'] as String,
      hash: json['hash'] as String,
      ids: ids,
      idMasks: masks,
      idKeyCounts: counts,
      models: models,
    );
  }
}

/// `b/<key>.k.json`: every key of a brand, in columns.
///
/// The file groups keys by remote id. A large brand has tens of thousands of
/// keys, so they are kept as parallel arrays rather than one object each:
/// row `r` of block `b` is the key ([labels]`[r]`, [protocols]`[r]`,
/// [hexes]`[r]`) of remote [ids]`[b]`, where `blockStart[b] <= r <
/// blockStart[b + 1]`.
class LedgerBrandKeys {
  LedgerBrandKeys({
    required this.brand,
    required this.ids,
    required this.blockStart,
    required this.labels,
    required this.protocols,
    required this.hexes,
  });

  final String brand;
  final Int32List ids;
  final Int32List blockStart;
  final List<String> labels;
  final Uint8List protocols;
  final List<String> hexes;

  int get rowCount => labels.length;

  Map<int, int>? _blockOfId;

  /// The block that holds row [row]: the one with `blockStart[b] <= row <
  /// blockStart[b + 1]`.
  int blockOfRow(int row) {
    int low = 0;
    int high = ids.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) >> 1;
      if (blockStart[mid] <= row) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// The block of remote [id], or -1.
  int blockOf(int id) {
    final Map<int, int> index = _blockOfId ??= <int, int>{
      for (int b = 0; b < ids.length; b++) ids[b]: b,
    };
    return index[id] ?? -1;
  }

  static LedgerBrandKeys parse(Uint8List bytes) {
    final dynamic json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['brand'] is! String || json['r'] is! List) {
      throw const FormatException('A brand key file is malformed.');
    }
    final List<dynamic> blocks = json['r'] as List<dynamic>;
    int rows = 0;
    for (final dynamic block in blocks) {
      if (block is! List || block.length < 2 || block[1] is! List) {
        throw const FormatException(
            'A block of a brand key file is malformed.');
      }
      rows += (block[1] as List<dynamic>).length;
    }
    final Int32List ids = Int32List(blocks.length);
    final Int32List starts = Int32List(blocks.length + 1);
    final List<String> labels = List<String>.filled(rows, '');
    final Uint8List protocols = Uint8List(rows);
    final List<String> hexes = List<String>.filled(rows, '');
    int r = 0;
    for (int b = 0; b < blocks.length; b++) {
      final List<dynamic> block = blocks[b] as List<dynamic>;
      final dynamic id = block[0];
      if (id is! int) {
        throw const FormatException('A block of a brand key file has no id.');
      }
      ids[b] = id;
      starts[b] = r;
      for (final dynamic key in block[1] as List<dynamic>) {
        if (key is! List ||
            key.length < 3 ||
            key[0] is! String ||
            key[1] is! int ||
            key[2] is! String) {
          throw const FormatException(
              'A key row of a brand file is malformed.');
        }
        labels[r] = key[0] as String;
        protocols[r] = key[1] as int;
        hexes[r] = key[2] as String;
        r++;
      }
    }
    starts[blocks.length] = r;
    return LedgerBrandKeys(
      brand: json['brand'] as String,
      ids: ids,
      blockStart: starts,
      labels: labels,
      protocols: protocols,
      hexes: hexes,
    );
  }
}

/// `s/<DB protocol>.json`: the ledger's compiled signal for every code of a
/// protocol the app does not decode itself.
class LedgerSignalShard {
  const LedgerSignalShard({
    required this.protocol,
    required this.ledger,
    required this.carrierHz,
    required this.carrierHzByLedger,
    required this.minSends,
    required this.play,
    required this.signals,
  });

  final String protocol;
  final List<String> ledger;
  final int? carrierHz;
  final Map<String, int> carrierHzByLedger;
  final int? minSends;
  final LedgerPlay? play;

  /// Pronto hex string by database hexcode.
  final Map<String, String> signals;

  static LedgerSignalShard parse(Uint8List bytes) {
    final dynamic json = jsonDecode(utf8.decode(bytes));
    if (json is! Map || json['p'] is! String || json['s'] is! Map) {
      throw const FormatException('A signal shard is malformed.');
    }
    final dynamic ledger = json['ledger'];
    final dynamic byLedger = json['carrierHzByLedger'];
    return LedgerSignalShard(
      protocol: json['p'] as String,
      ledger: ledger is List
          ? ledger.whereType<String>().toList(growable: false)
          : const <String>[],
      carrierHz: json['carrierHz'] is int ? json['carrierHz'] as int : null,
      carrierHzByLedger: byLedger is Map
          ? <String, int>{
              for (final MapEntry<dynamic, dynamic> e in byLedger.entries)
                if (e.key is String && e.value is int)
                  e.key as String: e.value as int,
            }
          : const <String, int>{},
      minSends: json['minSends'] is int ? json['minSends'] as int : null,
      play: LedgerPlay.fromJson(json['play']),
      signals: <String, String>{
        for (final MapEntry<dynamic, dynamic> e
            in (json['s'] as Map<dynamic, dynamic>).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      },
    );
  }
}

/// One row of `power.json`: a code whose label ranks as a power key.
class LedgerPowerRow {
  const LedgerPowerRow({
    required this.protoIdx,
    required this.hex,
    required this.label,
    required this.nIds,
    required this.rank,
  });

  final int protoIdx;
  final String hex;
  final String label;

  /// How many distinct remotes use the code under such a label: its
  /// popularity.
  final int nIds;

  /// The app's `powerLabelRank` of [label]: 0 (power on or off) or 1.
  final int rank;
}

/// `power.json`, most popular first.
List<LedgerPowerRow> parsePower(Uint8List bytes) {
  final dynamic json = jsonDecode(utf8.decode(bytes));
  if (json is! List) {
    throw const FormatException('power.json is not a list.');
  }
  final List<LedgerPowerRow> rows = <LedgerPowerRow>[];
  for (final dynamic row in json) {
    if (row is! List ||
        row.length < 5 ||
        row[0] is! int ||
        row[1] is! String ||
        row[2] is! String ||
        row[3] is! int ||
        row[4] is! int) {
      throw const FormatException('A row of power.json is malformed.');
    }
    rows.add(LedgerPowerRow(
      protoIdx: row[0] as int,
      hex: row[1] as String,
      label: row[2] as String,
      nIds: row[3] as int,
      rank: row[4] as int,
    ));
  }
  return rows;
}

/// The ledger's compiled signal for one database code, with what it takes to
/// play it: this is what stands in for the app's own decoding of the hex code
/// where [LedgerProtocol.appReadingDiffers].
class LedgerSignal {
  const LedgerSignal({
    required this.protocol,
    required this.hexcode,
    required this.pronto,
    required this.carrierHz,
    required this.minSends,
    required this.play,
  });

  /// The database protocol name (`SONY12`).
  final String protocol;
  final String hexcode;

  /// The Pronto hex string: carrier, intro sequence, repeat sequence.
  final String pronto;

  /// The carrier the ledger states for the protocol, or null.
  final int? carrierHz;
  final int? minSends;

  /// How one press is played; null only for an API that did not state it.
  final LedgerPlay? play;

  /// The press this signal makes: carrier and microsecond durations, or null
  /// when the Pronto string cannot be played.
  ///
  /// The count of repeat passes is the one the database states. Without one,
  /// the rule the app uses for a Remote Ledger file stands in
  /// (`remoteLedgerSends`, by `minSends`).
  LedgerPlayback? playback() {
    final LedgerPlay? stated = play;
    if (stated != null) {
      return ledgerPlayback(
        pronto,
        repeatPasses: stated.repeatPasses,
        carrierHz: carrierHz,
      );
    }
    final ProntoSequences? code =
        tryParseProntoSequences(pronto, minDurations: 2);
    if (code == null) return null;
    final List<int> pattern = remoteLedgerSends(code, minSends ?? 1);
    if (pattern.isEmpty) return null;
    final int? hz = carrierHz;
    return LedgerPlayback(
      frequencyHz:
          hz != null && hz >= 10000 && hz <= 200000 ? hz : code.frequencyHz,
      pattern: pattern,
    );
  }
}
