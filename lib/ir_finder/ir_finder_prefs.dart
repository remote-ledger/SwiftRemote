import 'dart:convert';

import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/ir_finder_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IrFinderPrefs {
  IrFinderPrefs._();

  static const String sessionKey = 'finder.session.v1';

  static Future<void> saveSession(IrFinderSessionSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(sessionKey, jsonEncode(snapshot.toJson()));
    } catch (_) {}
  }

  static Future<IrFinderSessionSnapshot?> loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(sessionKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final snapshot =
          IrFinderSessionSnapshot.fromJson(Map<String, dynamic>.from(map));
      if (snapshot.isFromAnOlderDatabase) {
        // Its offset counts keys of the bundled database's order, which the
        // IR code database no longer has; resuming would land somewhere else.
        await prefs.remove(sessionKey);
        return null;
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(sessionKey);
    } catch (_) {}
  }
}

class IrFinderSessionSnapshot {
  /// The version of a session as it is saved now. Version 3 counts a database
  /// session's `currentOffset` over the Remote Ledger's IR code database and
  /// records which data that was; versions 1 and 2 counted it over the sqlite
  /// the app used to bundle, in an order the new database does not reproduce
  /// (it lists each key once, not once per model).
  static const int currentVersion = 3;

  final int v;
  final IrFinderMode mode;
  final String protocolId;

  final String? brand;
  final String? model;

  final int delayMs;
  final int maxKeysToTest;

  final int bruteMaxAttempts;
  final bool bruteAllCombinations;
  final IrFinderSearchStrategy bruteStrategy;

  final String prefixRaw;
  final String kaseikyoVendor;

  final bool onlySelectedProtocol;
  final bool quickWinsFirst;

  final int attempted;
  final int currentOffset;

  final String bruteCursorHex;

  final int startedAtMs;
  final bool paused;

  /// The Remote Ledger's `dataVersion` the offset of a database session was
  /// counted over, and the content hash of the brand's key file; null for a
  /// session that was saved before the database was read, and for brute
  /// force.
  final String? dataVersion;
  final String? brandHash;

  const IrFinderSessionSnapshot({
    required this.v,
    required this.mode,
    required this.protocolId,
    required this.brand,
    required this.model,
    required this.delayMs,
    required this.maxKeysToTest,
    required this.bruteMaxAttempts,
    required this.bruteAllCombinations,
    required this.bruteStrategy,
    required this.prefixRaw,
    required this.kaseikyoVendor,
    required this.onlySelectedProtocol,
    required this.quickWinsFirst,
    required this.attempted,
    required this.currentOffset,
    required this.bruteCursorHex,
    required this.startedAtMs,
    required this.paused,
    this.dataVersion,
    this.brandHash,
  });

  /// Whether this is a database session saved by a version of the app that
  /// read the old bundled database.
  bool get isFromAnOlderDatabase =>
      mode == IrFinderMode.database && v < currentVersion;

  /// Whether a database session's offset still points at the key it did.
  ///
  /// The offset counts rows of the brand's selection, so it holds as long as
  /// the brand's keys are the ones it counted over: the same `dataVersion`
  /// says so for the whole database, and a brand file whose hash is unchanged
  /// says so for this brand when the rest of the database moved on. A session
  /// that never moved (offset 0) has nothing to lose. Brute force sessions
  /// have no database behind them.
  bool isResumableWith({String? dataVersion, String? brandHash}) {
    if (mode != IrFinderMode.database) return true;
    if (currentOffset == 0) return true;
    if (this.dataVersion != null && this.dataVersion == dataVersion) {
      return true;
    }
    return this.brandHash != null && this.brandHash == brandHash;
  }

  DateTime? get startedAt => startedAtMs <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(startedAtMs);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'v': v,
      'mode': mode.name,
      'protocolId': protocolId,
      'brand': brand,
      'model': model,
      'delayMs': delayMs,
      'maxKeysToTest': maxKeysToTest,
      'bruteMaxAttempts': bruteMaxAttempts,
      'bruteAllCombinations': bruteAllCombinations,
      'bruteStrategy': bruteStrategy.name,
      'prefixRaw': prefixRaw,
      'kaseikyoVendor': kaseikyoVendor,
      'onlySelectedProtocol': onlySelectedProtocol,
      'quickWinsFirst': quickWinsFirst,
      'attempted': attempted,
      'currentOffset': currentOffset,
      'bruteCursorHex': bruteCursorHex,
      'startedAtMs': startedAtMs,
      'paused': paused,
      if (dataVersion != null) 'dataVersion': dataVersion,
      if (brandHash != null) 'brandHash': brandHash,
    };
  }

  static IrFinderSessionSnapshot fromJson(Map<String, dynamic> j) {
    final String modeRaw =
        (j['mode'] as String?)?.trim().toLowerCase() ?? 'bruteforce';
    final IrFinderMode mode =
        modeRaw == 'database' ? IrFinderMode.database : IrFinderMode.bruteforce;

    final String protocolId =
        (j['protocolId'] as String?)?.trim().toLowerCase() ?? 'nec';

    return IrFinderSessionSnapshot(
      v: (j['v'] as int?) ?? 1,
      mode: mode,
      protocolId: protocolId,
      brand: (j['brand'] as String?)?.trim(),
      model: (j['model'] as String?)?.trim(),
      delayMs: ((j['delayMs'] as int?) ?? 500).clamp(250, 20000),
      maxKeysToTest: ((j['maxKeysToTest'] as int?) ?? 200).clamp(1, 2147483647),
      bruteMaxAttempts:
          ((j['bruteMaxAttempts'] as int?) ?? 200).clamp(1, 2147483647),
      bruteAllCombinations: (j['bruteAllCombinations'] as bool?) ?? false,
      bruteStrategy: j.containsKey('bruteStrategy')
          ? IrFinderSearchStrategyParsing.fromName(
              j['bruteStrategy'] as String?,
            )
          : IrFinderSearchStrategy.sequential,
      prefixRaw: (j['prefixRaw'] as String?) ?? '',
      kaseikyoVendor:
          ((j['kaseikyoVendor'] as String?) ?? '2002').toUpperCase(),
      onlySelectedProtocol: (j['onlySelectedProtocol'] as bool?) ?? true,
      quickWinsFirst: (j['quickWinsFirst'] as bool?) ?? true,
      attempted: ((j['attempted'] as int?) ?? 0).clamp(0, 2147483647),
      currentOffset: ((j['currentOffset'] as int?) ?? 0).clamp(0, 2147483647),
      bruteCursorHex: ((j['bruteCursorHex'] as String?) ?? '0').trim(),
      startedAtMs:
          ((j['startedAtMs'] as int?) ?? 0).clamp(0, 9223372036854775807),
      paused: (j['paused'] as bool?) ?? true,
      dataVersion: j['dataVersion'] as String?,
      brandHash: j['brandHash'] as String?,
    );
  }
}
