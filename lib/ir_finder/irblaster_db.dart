/* lib/ir_finder/irblaster_db.dart */
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ledger_db/ledger_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';
import 'package:swiftremote/ledger_db/ledger_selection.dart';
import 'package:swiftremote/ledger_db/sqlite_text.dart';

/// A code of the Universal Power list: one of the codes whose label ranks as a
/// power key, with the number of remotes that use it.
class IrDbPowerRow {
  const IrDbPowerRow({
    required this.protocol,
    required this.hexcode,
    required this.label,
    required this.nIds,
    required this.rank,
    required this.requiresSignal,
  });

  /// The database protocol name.
  final String protocol;
  final String hexcode;
  final String label;
  final int nIds;

  /// The app's `powerLabelRank` of [label], 0 or 1.
  final int rank;

  /// Whether the code is played from the ledger's compiled signal.
  final bool requiresSignal;
}

/// The IR code database: brands, models, protocols and keys, as the app's
/// screens ask for them.
///
/// The codes come from the Remote Ledger (`lib/ledger_db/`), read online and
/// kept on the device, and not from a bundled sqlite as they once did. The
/// questions and their answers are the same ones, in the same order:
///
/// * brands and models in `COLLATE NOCASE` order, searched with `LIKE %q%`;
/// * keys by the quick-wins rank when asked for, then `UPPER(label)`,
///   `UPPER(protocol)`, `UPPER(hexcode)` and the remote id; filtered by
///   protocol, hex prefix and a word in the label or the hex; paged by limit
///   and offset.
///
/// "ASCII" matters: SQLite folds only the 26 ASCII letters, so `é` and `É`
/// stay different here too (`lib/ledger_db/sqlite_text.dart`).
///
/// What changed on purpose:
///
/// * the old join returned one row per (model, key), so listing a whole brand
///   repeated every key once per model; each key is now listed once;
/// * nothing is read until it is asked for, and anything that needs the
///   network says so with [LedgerDbUnavailable] instead of failing quietly;
/// * for the protocols whose database codes the app decodes differently from
///   the wire, a row carries the ledger's compiled [LedgerSignal] and the app
///   plays that. See [IrDbKeyCandidate.requiresSignal].
class IrBlasterDb {
  IrBlasterDb._(this._ledger, this._run);

  static final IrBlasterDb instance = IrBlasterDb._(LedgerDb(), runOffloaded);

  @visibleForTesting
  factory IrBlasterDb.forTesting(
    LedgerDb ledger, {
    LedgerRunner runner = runInline,
  }) =>
      IrBlasterDb._(ledger, runner);

  final LedgerDb _ledger;
  final LedgerRunner _run;

  LedgerManifest? _manifest;
  List<LedgerBrand>? _brands;
  Map<String, LedgerBrand> _brandByName = <String, LedgerBrand>{};
  Future<void>? _initFuture;

  /// The ledger's `dataVersion` the answers come from, once the database has
  /// been initialised.
  String? get dataVersion => _manifest?.dataVersion;

  /// Reads the manifest and the brand list, from the device or, when they are
  /// not there or are older than half a day, the network. Cheap once done.
  ///
  /// Throws [LedgerDbUnavailable] when they cannot be had from anywhere. A
  /// failed call can simply be made again.
  Future<void> ensureInitialized() {
    final Future<void>? running = _initFuture;
    if (running != null) return running;
    final Future<void> f = _initialize();
    _initFuture = f;
    void done() {
      if (identical(_initFuture, f)) _initFuture = null;
    }

    unawaited(f.then<void>((_) => done(), onError: (Object _) => done()));
    return f;
  }

  Future<void> _initialize() async {
    final LedgerManifest manifest = await _ledger.manifest();
    if (_manifest?.dataVersion != manifest.dataVersion) {
      _selections.clear();
      _pinned = null;
      _brands = null;
    }
    final List<LedgerBrand> brands = await _ledger.brands();
    if (!identical(brands, _brands)) {
      _brandByName = <String, LedgerBrand>{
        for (final LedgerBrand b in brands) b.name: b,
      };
      _brands = brands;
    }
    _manifest = manifest;
  }

  Future<void> _ready() {
    if (_manifest != null && _brands != null) return Future<void>.value();
    return ensureInitialized();
  }

  // ---- protocol normalisation ----

  _ProtocolFilter? _resolveProtocolFilter(String? selectedProtocolId) {
    final String? s =
        (selectedProtocolId == null || selectedProtocolId.trim().isEmpty)
            ? null
            : selectedProtocolId.trim();
    if (s == null) return null;
    final String key = protocolKey(s);
    if (key.isEmpty) return null;

    int mask = 0;
    for (final LedgerProtocol p in _manifest!.protocols) {
      if (p.key == key) mask |= 1 << p.index;
    }
    return _ProtocolFilter(key: key, mask: mask);
  }

  static String? _trimmedOrNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  static List<T> _page<T>(Iterable<T> items, int limit, int offset) {
    Iterable<T> it = items;
    if (offset > 0) it = it.skip(offset);
    if (limit >= 0) it = it.take(limit);
    return it.toList(growable: false);
  }

  // ---- brands, models, protocols ----

  Future<List<String>> listProtocolsFor({
    required String brand,
    required String model,
  }) async {
    await _ready();
    final String b = brand.trim();
    final String m = model.trim();
    if (b.isEmpty || m.isEmpty) return <String>[];
    final LedgerBrand? entry = _brandByName[b];
    if (entry == null) return <String>[];
    final LedgerBrandModels models = await _ledger.brandModels(entry.key);
    final LedgerModel? found = models.model(m);
    if (found == null) return <String>[];
    return _protocolNames(models.maskOf(found.idIndexes));
  }

  /// Returns distinct protocols used by [brand] across all its models,
  /// ordered alphabetically. Used to auto-adjust the protocol when a
  /// brand is selected in the IR Finder without a protocol filter.
  Future<List<String>> listProtocolsForBrand(String brand) async {
    await _ready();
    final String b = brand.trim();
    if (b.isEmpty) return <String>[];
    final LedgerBrand? entry = _brandByName[b];
    if (entry == null) return <String>[];
    return _protocolNames(entry.protoMask);
  }

  /// The protocols in [mask], by `UPPER(name)`.
  List<String> _protocolNames(int mask) {
    final List<String> names = <String>[
      for (final LedgerProtocol p in _manifest!.protocols)
        if ((mask >> p.index) & 1 == 1) p.db.trim(),
    ]..sort(
        (String a, String b) => compareBinary(asciiUpper(a), asciiUpper(b)));
    return names;
  }

  Future<List<String>> listBrands({
    String? search,
    String? protocolId,
    int limit = 60,
    int offset = 0,
  }) async {
    await _ready();
    final String? q = _trimmedOrNull(search);
    final _ProtocolFilter? pf = _resolveProtocolFilter(protocolId);

    // Brand names are exactly the strings the models were filed under, so the
    // follow-up queries that match them exactly (protocols, models, keys)
    // find what the list showed.
    Iterable<LedgerBrand> brands = _brands!;
    if (pf != null) {
      brands = brands.where((LedgerBrand b) => (b.protoMask & pf.mask) != 0);
    }
    if (q != null) {
      brands = brands.where((LedgerBrand b) => likeContains(b.name, q));
    }
    return _page(brands.map((LedgerBrand b) => b.name), limit, offset);
  }

  Future<List<String>> listModelsDistinct({
    required String brand,
    String? search,
    String? protocolId,
    int limit = 60,
    int offset = 0,
  }) async {
    await _ready();
    final String b = brand.trim();
    if (b.isEmpty) return <String>[];
    final LedgerBrand? entry = _brandByName[b];
    if (entry == null) return <String>[];

    final String? q = _trimmedOrNull(search);
    final _ProtocolFilter? pf = _resolveProtocolFilter(protocolId);
    final LedgerBrandModels models = await _ledger.brandModels(entry.key);

    Iterable<LedgerModel> list = models.models;
    if (pf != null) {
      list = list.where(
        (LedgerModel m) => (models.maskOf(m.idIndexes) & pf.mask) != 0,
      );
    }
    if (q != null) {
      list = list.where((LedgerModel m) => likeContains(m.name, q));
    }
    return _page(list.map((LedgerModel m) => m.name), limit, offset);
  }

  // ---- keys ----

  final Map<String, _Selection> _selections = <String, _Selection>{};
  _Selection? _pinned;

  LedgerSelectionRequest _request({
    String? model,
    String? selectedProtocolId,
    required bool quickWinsFirst,
    String? hexPrefixUpper,
    String? search,
  }) {
    final String? m = _trimmedOrNull(model);
    final String? prefix =
        (hexPrefixUpper == null || hexPrefixUpper.trim().isEmpty)
            ? null
            : hexPrefixUpper.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    return LedgerSelectionRequest(
      model: m,
      protocolKey: _resolveProtocolFilter(selectedProtocolId)?.key,
      quickWinsFirst: quickWinsFirst,
      hexPrefix: prefix,
      search: _trimmedOrNull(search),
    );
  }

  /// The rows a question selects, in order, kept by the question's arguments:
  /// the IR Finder asks for them one at a time (`limit: 1`, offset 0, 1, 2,
  /// ...) and must not pay for the filtering and the sort each time.
  Future<_Selection?> _selection(
    String brand,
    LedgerSelectionRequest request, {
    required bool sorted,
  }) async {
    final LedgerBrand? entry = _brandByName[brand];
    if (entry == null) return null;
    final String signature =
        '${entry.key}\u0001${request.signature}\u0001$sorted';

    final _Selection? pinned = _pinned;
    if (pinned != null && pinned.signature == signature) return pinned;
    final _Selection? cached = _selections.remove(signature);
    if (cached != null) {
      _selections[signature] = cached;
      return cached;
    }

    final LedgerBrandData data = await _ledger.brand(entry.key);
    final LedgerSelectionInput input = LedgerSelectionInput(
      keys: data.keys,
      models: data.models,
      protocolNames: <String>[
        for (final LedgerProtocol p in _manifest!.protocols) p.db,
      ],
      request: request,
      sorted: sorted,
    );
    final int estimate = request.model == null
        ? data.keys.rowCount
        : _modelRows(data, request.model!);
    final Int32List rows = await _runSelection(_run, input, estimate * 8);
    final _Selection selection = _Selection(
      signature: signature,
      brand: entry,
      data: data,
      model: request.model,
      rows: rows,
    );
    _selections[signature] = selection;
    while (_selections.length > 6) {
      _selections.remove(_selections.keys.first);
    }
    return selection;
  }

  static int _modelRows(LedgerBrandData data, String model) {
    final LedgerModel? m = data.models.model(model);
    if (m == null) return 0;
    int total = 0;
    for (final int i in m.idIndexes) {
      if (i >= 0 && i < data.models.idKeyCounts.length) {
        total += data.models.idKeyCounts[i];
      }
    }
    return total;
  }

  Future<List<IrDbKeyCandidate>> fetchCandidateKeys({
    required String brand,
    String? model,
    String? selectedProtocolId,
    required bool quickWinsFirst,
    String? hexPrefixUpper,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    await _ready();
    final String b = brand.trim();
    if (b.isEmpty) return <IrDbKeyCandidate>[];

    final _Selection? selection = await _selection(
      b,
      _request(
        model: model,
        selectedProtocolId: selectedProtocolId,
        quickWinsFirst: quickWinsFirst,
        hexPrefixUpper: hexPrefixUpper,
        search: search,
      ),
      sorted: true,
    );
    if (selection == null) return <IrDbKeyCandidate>[];

    final int from = math.min(math.max(offset, 0), selection.rows.length);
    final int to = limit < 0
        ? selection.rows.length
        : math.min(from + limit, selection.rows.length);
    if (from >= to) return <IrDbKeyCandidate>[];

    final LedgerBrandKeys keys = selection.data.keys;
    // Load the signals the page needs before building any row, so that a
    // network failure fails the whole page rather than leaving a row that
    // looks usable and is not.
    final Map<int, LedgerSignalShard> shards = <int, LedgerSignalShard>{};
    for (int i = from; i < to; i++) {
      final int protocolIndex = keys.protocols[selection.rows[i]];
      final LedgerProtocol? protocol = _protocolAt(protocolIndex);
      if (protocol != null &&
          protocol.appReadingDiffers &&
          !shards.containsKey(protocolIndex)) {
        shards[protocolIndex] = await _ledger.signalShard(protocol.db);
      }
    }

    final List<IrDbKeyCandidate> out = <IrDbKeyCandidate>[];
    for (int i = from; i < to; i++) {
      final int row = selection.rows[i];
      final LedgerProtocol? protocol = _protocolAt(keys.protocols[row]);
      if (protocol == null) continue;
      final int id = keys.ids[keys.blockOfRow(row)];
      final String hex = keys.hexes[row];
      out.add(IrDbKeyCandidate(
        id: id,
        protocol: protocol.db,
        hexcode: hex,
        remoteId: id,
        label: keys.labels[row],
        brand: selection.brand.name,
        model: selection.model ?? selection.data.models.firstModelOfId(id),
        requiresSignal: protocol.appReadingDiffers,
        signal: protocol.appReadingDiffers
            ? _signalOf(protocol, shards[protocol.index]!, hex)
            : null,
      ));
    }
    return out;
  }

  Future<int> countCandidateKeys({
    required String brand,
    String? model,
    String? selectedProtocolId,
    String? hexPrefixUpper,
    String? search,
  }) async {
    await _ready();
    final String b = brand.trim();
    if (b.isEmpty) return 0;
    final _Selection? selection = await _selection(
      b,
      _request(
        model: model,
        selectedProtocolId: selectedProtocolId,
        quickWinsFirst: false,
        hexPrefixUpper: hexPrefixUpper,
        search: search,
      ),
      sorted: false,
    );
    return selection?.rows.length ?? 0;
  }

  /// Loads everything a run through a selection will touch (the brand's files,
  /// the filtered and sorted rows, and the signals of every protocol that is
  /// played from one) and returns how many keys it holds. A later
  /// [fetchCandidateKeys] with the same arguments then needs no network, so a
  /// timer driving it one row at a time cannot hit a failure half way.
  ///
  /// The selection stays in memory until the next call.
  Future<int> prepareCandidates({
    required String brand,
    String? model,
    String? selectedProtocolId,
    required bool quickWinsFirst,
    String? hexPrefixUpper,
    String? search,
  }) async {
    await _ready();
    final String b = brand.trim();
    if (b.isEmpty) return 0;
    final _Selection? selection = await _selection(
      b,
      _request(
        model: model,
        selectedProtocolId: selectedProtocolId,
        quickWinsFirst: quickWinsFirst,
        hexPrefixUpper: hexPrefixUpper,
        search: search,
      ),
      sorted: true,
    );
    if (selection == null) return 0;

    final Set<int> present = <int>{};
    final LedgerBrandKeys keys = selection.data.keys;
    for (int i = 0; i < selection.rows.length; i++) {
      present.add(keys.protocols[selection.rows[i]]);
    }
    for (final int index in present) {
      final LedgerProtocol? protocol = _protocolAt(index);
      if (protocol != null && protocol.appReadingDiffers) {
        await _ledger.signalShard(protocol.db);
      }
    }
    _pinned = selection;
    return selection.rows.length;
  }

  /// The content hash of a brand's key file (`b/<key>.m.json`'s `hash`), which
  /// changes when any key of the brand does; null for a brand the database
  /// does not have.
  Future<String?> brandContentHash(String brand) async {
    await _ready();
    final LedgerBrand? entry = _brandByName[brand.trim()];
    if (entry == null) return null;
    return (await _ledger.brandModels(entry.key)).hash;
  }

  // ---- signals and the power list ----

  LedgerProtocol? _protocolAt(int index) {
    final List<LedgerProtocol> list = _manifest!.protocols;
    return (index >= 0 && index < list.length) ? list[index] : null;
  }

  LedgerSignal? _signalOf(
    LedgerProtocol protocol,
    LedgerSignalShard shard,
    String hex,
  ) {
    final String? pronto = shard.signals[hex];
    if (pronto == null) return null;
    return LedgerSignal(
      protocol: protocol.db,
      hexcode: hex,
      pronto: pronto,
      carrierHz: shard.carrierHz ?? protocol.carrierHz,
      minSends: shard.minSends ?? protocol.minSends,
      play: shard.play ?? protocol.play,
    );
  }

  /// Whether codes of the database protocol [dbProtocol] are played from the
  /// ledger's compiled signal. Needs [ensureInitialized] to have succeeded.
  bool requiresSignal(String dbProtocol) {
    final LedgerManifest? m = _manifest;
    if (m == null) return false;
    return m.protocolByDb(dbProtocol)?.appReadingDiffers ?? false;
  }

  /// The compiled signal of one code of a protocol that has them, or null
  /// when the database has none for that code. Loads the protocol's file on
  /// first use (once per protocol).
  ///
  /// Throws [LedgerDbUnavailable] when the file is neither cached nor
  /// reachable.
  Future<LedgerSignal?> signalFor(String dbProtocol, String hexcode) async {
    await _ready();
    final LedgerProtocol? protocol = _manifest!.protocolByDb(dbProtocol);
    if (protocol == null || !protocol.appReadingDiffers) return null;
    final LedgerSignalShard shard = await _ledger.signalShard(protocol.db);
    return _signalOf(protocol, shard, hexcode);
  }

  /// The Universal Power list for all brands: the codes whose label ranks as
  /// a power key, the ones used by most remotes first.
  Future<List<IrDbPowerRow>> powerRows() async {
    await _ready();
    final List<LedgerPowerRow> rows = await _ledger.power();
    final List<IrDbPowerRow> out = <IrDbPowerRow>[];
    for (final LedgerPowerRow r in rows) {
      final LedgerProtocol? protocol = _protocolAt(r.protoIdx);
      if (protocol == null) continue;
      out.add(IrDbPowerRow(
        protocol: protocol.db,
        hexcode: r.hex,
        label: r.label,
        nIds: r.nIds,
        rank: r.rank,
        requiresSignal: protocol.appReadingDiffers,
      ));
    }
    return out;
  }
}

/// A top-level function, so that the closure handed to the runner captures
/// only [input], which can cross to another isolate, and not the database.
Future<Int32List> _runSelection(
  LedgerRunner run,
  LedgerSelectionInput input,
  int weight,
) {
  return run<Int32List>(() => buildSelection(input), weight: weight);
}

class _ProtocolFilter {
  const _ProtocolFilter({required this.key, required this.mask});

  /// The normalised key the caller's spelling reduces to.
  final String key;

  /// The bits of the manifest's protocols that have that key. Zero for a
  /// spelling the database has no protocol for, which matches nothing.
  final int mask;
}

class _Selection {
  _Selection({
    required this.signature,
    required this.brand,
    required this.data,
    required this.model,
    required this.rows,
  });

  final String signature;
  final LedgerBrand brand;
  final LedgerBrandData data;
  final String? model;

  /// Row numbers of [LedgerBrandData.keys], in the order they are listed.
  final Int32List rows;
}
