import 'dart:typed_data';

import 'package:swiftremote/ledger_db/ledger_models.dart';
import 'package:swiftremote/ledger_db/sqlite_text.dart';

/// What `fetchCandidateKeys` and `countCandidateKeys` ask of a brand's keys,
/// already normalised the way the old SQL layer normalised it.
class LedgerSelectionRequest {
  const LedgerSelectionRequest({
    this.model,
    this.protocolKey,
    this.quickWinsFirst = false,
    this.hexPrefix,
    this.search,
  });

  /// The model whose remote ids supply the keys; null for every id of the
  /// brand.
  final String? model;

  /// A protocol, as [protocolKey] spells it; only keys of that protocol.
  final String? protocolKey;

  /// Order the power, mute, volume, channel and navigation keys first.
  final bool quickWinsFirst;

  /// A prefix of the hexcode, no spaces, upper case.
  final String? hexPrefix;

  /// A word to find in the label or the hexcode, trimmed.
  final String? search;

  /// A key that is the same for the same question, for caching the answer.
  String get signature =>
      '${model ?? ''}\u0000${protocolKey ?? ''}\u0000$quickWinsFirst\u0000'
      '${hexPrefix ?? ''}\u0000${search ?? ''}';
}

/// Everything [buildSelection] reads, as one object so that it can be handed
/// to another isolate.
class LedgerSelectionInput {
  const LedgerSelectionInput({
    required this.keys,
    required this.models,
    required this.protocolNames,
    required this.request,
    required this.sorted,
  });

  final LedgerBrandKeys keys;
  final LedgerBrandModels models;

  /// Database protocol names, by the index a key row carries.
  final List<String> protocolNames;
  final LedgerSelectionRequest request;

  /// Whether to put the rows in the order `fetchCandidateKeys` returns them
  /// in. A count does not need it.
  final bool sorted;
}

/// The rows of [LedgerSelectionInput.keys] that a query selects: the keys of
/// the model's remotes (or of all the brand's), filtered, and de-duplicated by
/// construction, since each remote's keys are listed once whatever number of
/// models it belongs to.
///
/// With [LedgerSelectionInput.sorted], in the order the old SQL gave:
///
/// 1. with `quickWinsFirst`, the `CASE` rank: 0 for power, 1 for mute, 2 for
///    volume, 3 for channel, 4 for navigation, 9 for the rest;
/// 2. `UPPER(label)`, `UPPER(protocol)`, `UPPER(hexcode)`, then the remote id,
///    each compared as SQLite's BINARY collation does.
///
/// SQLite left ties in that order to chance (two keys of one remote that
/// differ only in the case of a label). Here they fall in the order of their
/// exact text, so that the order is total and the same on every device.
Int32List buildSelection(LedgerSelectionInput input) {
  final LedgerBrandKeys keys = input.keys;
  final LedgerSelectionRequest req = input.request;

  // The blocks (one per remote id) the keys come from.
  final List<int> blocks = <int>[];
  final String? modelName = req.model;
  if (modelName != null) {
    final LedgerModel? model = input.models.model(modelName);
    if (model == null) return Int32List(0);
    final Set<int> seen = <int>{};
    for (final int index in model.idIndexes) {
      if (index < 0 || index >= input.models.ids.length) continue;
      final int block = keys.blockOf(input.models.ids[index]);
      if (block >= 0 && seen.add(block)) blocks.add(block);
    }
  } else {
    final Set<int> seen = <int>{};
    for (final int id in input.models.ids) {
      final int block = keys.blockOf(id);
      if (block >= 0 && seen.add(block)) blocks.add(block);
    }
  }

  // Protocol filter: which protocol indexes pass.
  final Uint8List protocolPasses = Uint8List(256);
  final List<String> names = input.protocolNames;
  for (int i = 0; i < names.length && i < 256; i++) {
    final String? wanted = req.protocolKey;
    protocolPasses[i] =
        (wanted == null || protocolKey(names[i]) == wanted) ? 1 : 0;
  }

  final String? prefix = req.hexPrefix;
  final String? prefixUpper = prefix == null ? null : asciiUpper(prefix);
  final bool prefixHasWildcard =
      prefix != null && (prefix.contains('%') || prefix.contains('_'));

  final String? search = req.search;
  final String? labelNeedle = search == null ? null : asciiUpper(search);
  final String? hexPattern =
      search == null ? null : '%${escapeLike(search).toUpperCase()}%';

  final List<int> picked = <int>[];
  final List<int> pickedIds = <int>[];
  for (final int block in blocks) {
    for (int r = keys.blockStart[block]; r < keys.blockStart[block + 1]; r++) {
      final int protocolIndex = keys.protocols[r];
      if (protocolIndex >= names.length || protocolPasses[protocolIndex] == 0) {
        continue;
      }
      final String hex = keys.hexes[r];
      if (prefixUpper != null) {
        if (prefixHasWildcard) {
          if (!sqliteLike('$prefix%', hex)) continue;
        } else if (!asciiUpper(hex).startsWith(prefixUpper)) {
          continue;
        }
      }
      if (labelNeedle != null) {
        final bool inLabel = asciiUpper(keys.labels[r]).contains(labelNeedle);
        if (!inLabel && !sqliteLike(hexPattern!, hex)) continue;
      }
      picked.add(r);
      pickedIds.add(keys.ids[block]);
    }
  }

  if (!input.sorted || picked.length < 2) {
    return Int32List.fromList(picked);
  }

  // Sort keys, computed once per row.
  final int n = picked.length;
  final bool quick = req.quickWinsFirst;
  final List<String> upLabel = List<String>.filled(n, '');
  final List<String> upHex = List<String>.filled(n, '');
  final Uint8List rank = Uint8List(n);
  final Int32List ids = Int32List.fromList(pickedIds);
  for (int i = 0; i < n; i++) {
    final int r = picked[i];
    final String up = asciiUpper(keys.labels[r]);
    upLabel[i] = up;
    upHex[i] = asciiUpper(keys.hexes[r]);
    if (quick) rank[i] = quickWinRank(up);
  }

  // The order of the protocols by UPPER(name), as a rank per protocol index.
  final List<int> byUpperName = List<int>.generate(names.length, (int i) => i)
    ..sort((int a, int b) =>
        compareBinary(asciiUpper(names[a]), asciiUpper(names[b])));
  final Int32List protocolRank = Int32List(256);
  for (int position = 0; position < byUpperName.length; position++) {
    protocolRank[byUpperName[position]] = position;
  }

  final List<int> order = List<int>.generate(n, (int i) => i);
  order.sort((int a, int b) {
    if (quick) {
      final int byRank = rank[a].compareTo(rank[b]);
      if (byRank != 0) return byRank;
    }
    int c = compareBinary(upLabel[a], upLabel[b]);
    if (c != 0) return c;
    final int ra = picked[a];
    final int rb = picked[b];
    c = protocolRank[keys.protocols[ra]]
        .compareTo(protocolRank[keys.protocols[rb]]);
    if (c != 0) return c;
    c = compareBinary(upHex[a], upHex[b]);
    if (c != 0) return c;
    c = ids[a].compareTo(ids[b]);
    if (c != 0) return c;
    // A tie SQLite leaves to chance: the exact text decides.
    c = compareBinary(keys.labels[ra], keys.labels[rb]);
    if (c != 0) return c;
    c = compareBinary(names[keys.protocols[ra]], names[keys.protocols[rb]]);
    if (c != 0) return c;
    return compareBinary(keys.hexes[ra], keys.hexes[rb]);
  });

  final Int32List out = Int32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = picked[order[i]];
  }
  return out;
}

/// The `CASE` of the old `quickWinsFirst` ordering, on an upper-cased label.
int quickWinRank(String upperLabel) {
  if (upperLabel.contains('POWER') ||
      upperLabel == 'PWR' ||
      upperLabel == 'ON' ||
      upperLabel == 'OFF') {
    return 0;
  }
  if (upperLabel.contains('MUTE')) return 1;
  if (upperLabel.startsWith('VOL') || upperLabel.contains('VOLUME')) return 2;
  if (upperLabel.startsWith('CH') || upperLabel.contains('CHANNEL')) return 3;
  if (_navigation.contains(upperLabel)) return 4;
  return 9;
}

const Set<String> _navigation = <String>{
  'OK',
  'ENTER',
  'MENU',
  'HOME',
  'BACK',
  'UP',
  'DOWN',
  'LEFT',
  'RIGHT',
};
