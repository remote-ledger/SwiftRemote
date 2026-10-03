import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';
import 'package:swiftremote/universal_power/curated_power_patterns.dart';
import 'package:swiftremote/universal_power/power_code.dart';

class PowerCodeRepository {
  PowerCodeRepository({required this.db});

  final IrBlasterDb db;

  /// The database protocols whose codes were left out of the last
  /// [loadAllPowerCodes] because their signal could not be loaded (offline,
  /// and not cached yet). Those codes cannot be sent without it; they are not
  /// decoded some other way.
  Set<String> get skippedSignalProtocols =>
      Set<String>.unmodifiable(_skippedSignalProtocols);
  final Set<String> _skippedSignalProtocols = <String>{};

  /// The queue for one brand (and, when given, model): its power keys, found
  /// by the labels the app knows power keys by, the likeliest first.
  ///
  /// Throws [LedgerDbUnavailable] when the brand's codes cannot be read.
  Future<List<PowerCode>> loadPowerCodes({
    required String brand,
    String? model,
    bool broadenSearch = false,
    int maxCodes = 600,
    int depth = 2,
  }) async {
    await db.ensureInitialized();

    final List<PowerCode> codes = <PowerCode>[];
    final Set<String> seen = <String>{};
    final int maxRank = _maxRankForDepth(depth, broadenSearch: broadenSearch);

    void addCode(PowerCode code) {
      final int rank = powerLabelRank(code.label);
      if (rank > maxRank) return;
      final String key = _dedupeKey(code);
      if (!seen.add(key)) return;
      codes.add(code);
    }

    final String brandNorm = brand.trim().toLowerCase();
    for (final p in curatedPowerPatterns) {
      if (p.brand.trim().toLowerCase() != brandNorm) continue;
      addCode(PowerCode(
        protocolId: 'raw',
        hexCode: '',
        label: 'POWER',
        brand: brand,
        model: model,
        frequencyHz: p.frequencyHz,
        rawPattern: p.cycles,
      ));
      if (codes.length >= maxCodes) return codes;
    }

    Future<void> addFromQuery(String? query, {int limit = 220}) async {
      final rows = await db.fetchCandidateKeys(
        brand: brand,
        model: model,
        selectedProtocolId: null,
        quickWinsFirst: true,
        search: query,
        limit: limit,
        offset: 0,
      );

      for (final r in rows) {
        final label = (r.label ?? '').trim();
        if (label.isEmpty) continue;
        addCode(PowerCode(
          protocolId: _normalizedProtocolId(r.protocol),
          hexCode: r.hexcode,
          label: label,
          brand: r.brand,
          model: r.model,
          requiresSignal: r.requiresSignal,
          signal: r.signal,
        ));
        if (codes.length >= maxCodes) return;
      }
    }

    await addFromQuery('power');
    if (codes.length < maxCodes) await addFromQuery('off');
    if (codes.length < maxCodes) await addFromQuery('pwr');
    if (codes.length < maxCodes) await addFromQuery('standby');
    if (codes.length < maxCodes) await addFromQuery('sleep');

    if (codes.isEmpty && broadenSearch) {
      await addFromQuery(null, limit: maxCodes);
    }

    if (codes.isEmpty) return codes;

    codes.sort(_byRankBrandLabel);

    if (codes.length > maxCodes) {
      return codes.sublist(0, maxCodes);
    }
    return codes;
  }

  /// The queue for "all brands": the curated raw patterns, then the codes the
  /// IR code database holds under power labels, the ones used by most remotes
  /// first (the ledger's `power.json`, one row per distinct code).
  ///
  /// Throws [LedgerDbUnavailable] when that list cannot be read. A code of a
  /// protocol the app plays from the database's compiled signal is queued
  /// only when that signal could be loaded; see [skippedSignalProtocols].
  Future<List<PowerCode>> loadAllPowerCodes({
    bool broadenSearch = false,
    int maxCodes = 1200,
    int depth = 2,
  }) async {
    await db.ensureInitialized();
    _skippedSignalProtocols.clear();

    final List<PowerCode> codes = <PowerCode>[];
    final Set<String> seen = <String>{};
    final int maxRank = _maxRankForDepth(depth, broadenSearch: broadenSearch);

    void addCode(PowerCode code) {
      final int rank = powerLabelRank(code.label);
      if (rank > maxRank) return;
      final String key = _dedupeKey(code);
      if (!seen.add(key)) return;
      codes.add(code);
    }

    for (final p in curatedPowerPatterns) {
      addCode(PowerCode(
        protocolId: 'raw',
        hexCode: '',
        label: 'POWER',
        brand: p.brand,
        frequencyHz: p.frequencyHz,
        rawPattern: p.cycles,
      ));
      if (codes.length >= maxCodes) return codes;
    }

    final List<IrDbPowerRow> rows = await db.powerRows();
    // Whether each signal protocol's file could be had; asked once.
    final Map<String, bool> signalsAvailable = <String, bool>{};

    for (final IrDbPowerRow r in rows) {
      if (codes.length >= maxCodes) break;
      final String label = r.label.trim();
      if (label.isEmpty) continue;
      if (powerLabelRank(label) > maxRank) continue;

      LedgerSignal? signal;
      if (r.requiresSignal) {
        if (signalsAvailable[r.protocol] == false) continue;
        try {
          signal = await db.signalFor(r.protocol, r.hexcode);
          signalsAvailable[r.protocol] = true;
        } on LedgerDbUnavailable {
          signalsAvailable[r.protocol] = false;
          _skippedSignalProtocols.add(r.protocol);
          continue;
        }
        // A code with no signal in the database is not one the app can play.
        if (signal == null) continue;
      }

      addCode(PowerCode(
        protocolId: _normalizedProtocolId(r.protocol),
        hexCode: r.hexcode,
        label: label,
        requiresSignal: r.requiresSignal,
        signal: signal,
      ));
    }

    return codes;
  }

  static String _normalizedProtocolId(String dbProtocol) =>
      dbProtocol.trim().toLowerCase().replaceAll('-', '_');

  static int _byRankBrandLabel(PowerCode a, PowerCode b) {
    final int ra = powerLabelRank(a.label);
    final int rb = powerLabelRank(b.label);
    if (ra != rb) return ra.compareTo(rb);
    final int byBrand =
        (a.brand ?? '').toUpperCase().compareTo((b.brand ?? '').toUpperCase());
    if (byBrand != 0) return byBrand;
    final int byLabel = a.label.toUpperCase().compareTo(b.label.toUpperCase());
    if (byLabel != 0) return byLabel;
    final int byProto = a.protocolId.compareTo(b.protocolId);
    if (byProto != 0) return byProto;
    return a.hexCode.compareTo(b.hexCode);
  }
}

int _maxRankForDepth(int depth, {required bool broadenSearch}) {
  final int d = depth.clamp(1, 4);
  if (broadenSearch) return 3;
  switch (d) {
    case 1:
      return 0;
    case 2:
      return 1;
    case 3:
      return 2;
    default:
      return 3;
  }
}

/// What makes two queue entries the same code: its protocol, hexcode and
/// label. The database lists one remote's keys once under every model that
/// uses it, and the same code under many brands, so the model and the brand
/// are not part of it: sending a code twice finds nothing the first send did
/// not.
String _dedupeKey(PowerCode code) {
  if (code.rawPattern != null && code.frequencyHz != null) {
    return 'raw|${code.frequencyHz}|${code.rawPattern!.join(',')}|${code.brand ?? ''}|${code.model ?? ''}';
  }
  return '${code.protocolId}|${code.hexCode}|${code.label}';
}
