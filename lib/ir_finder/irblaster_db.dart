/* lib/ir_finder/irblaster_db.dart */
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class IrBlasterDb {
  IrBlasterDb._();
  static final IrBlasterDb instance = IrBlasterDb._();

  static const String _assetDbPath = 'assets/db/swiftremote.sqlite';
  static const String _dbFileName = 'swiftremote.sqlite';

  /// The name this database had before the app was renamed to SwiftRemote.
  /// An install that upgrades from one of those builds still has the old
  /// copy sitting in the databases directory; it is never read again, so
  /// delete it rather than leave tens of megabytes behind.
  static const String _legacyDbFileName = 'irblaster.sqlite';

  /// Bump this by hand whenever assets/db/swiftremote.sqlite is regenerated.
  /// The copy in the databases directory is only refreshed when the marker
  /// beside it disagrees with this number, so a corrected database actually
  /// reaches installs that already ran the app instead of being ignored for
  /// the life of the install. Comparing the two by content would mean
  /// unpacking and hashing fifty megabytes of asset every time the finder is
  /// opened, which is far too slow for a file that changes once or twice a
  /// year, and the app already invalidates its GitHub directory cache with
  /// the same kind of hand-bumped constant.
  static const int _assetDbVersion = 1;

  /// Records the [_assetDbVersion] that produced the database sitting next to
  /// it. The marker lives in the databases directory rather than in the
  /// shared preferences so that it is created, backed up, restored and wiped
  /// together with the file it describes; a marker kept anywhere else could
  /// outlive that file and vouch for a database that is no longer there.
  static const String _dbVersionFileName = 'swiftremote.sqlite.version';

  Database? _db;
  Future<void>? _initFuture;
  bool _perfTuned = false;

  // Protocol normalization cache: normalizedKey -> canonical DB value as stored in keys.protocol
  bool _protocolMapLoaded = false;
  final Map<String, String> _canonicalProtocolByKey = <String, String>{};

  Future<void> ensureInitialized() {
    _initFuture ??= _open();
    return _initFuture!;
  }

  Future<void> _open() async {
    if (_db != null) return;

    final String dbDir = await getDatabasesPath();
    final String dbPath = p.join(dbDir, _dbFileName);
    final String versionPath = p.join(dbDir, _dbVersionFileName);

    await _deleteLegacyDb(dbDir);

    if (!await _hasUsableDb(dbPath)) {
      // There is no database to fall back on, so a failure here has to reach
      // the caller rather than be swallowed into an empty finder.
      await _installAssetDb(dbPath, versionPath);
    } else if (await _readInstalledDbVersion(versionPath) != _assetDbVersion) {
      try {
        await _installAssetDb(dbPath, versionPath);
      } catch (_) {
        // The database on disk is readable, merely older than the one we
        // ship. Serving slightly stale codes beats refusing to open the
        // finder at all, and the refresh is attempted again next time
        // because the marker is only written by a copy that completed.
      }
    }

    // Open writable so we can create indexes (no data mutations; just performance indexes).
    _db = await openDatabase(
      dbPath,
      readOnly: false,
      singleInstance: true,
    );

    await _ensurePerformanceTuning();
  }

  Future<void> _deleteLegacyDb(String dbDir) async {
    await _deleteQuietly(File(p.join(dbDir, _legacyDbFileName)));
  }

  /// Whether the databases directory already holds something worth opening.
  /// The length test is what catches an install that was interrupted while
  /// the asset was being unpacked: such a file still answers databaseExists
  /// but has no header for SQLite to read.
  Future<bool> _hasUsableDb(String dbPath) async {
    if (!await databaseExists(dbPath)) return false;
    final File f = File(dbPath);
    if (!await f.exists()) return false;
    return await f.length() > 0;
  }

  /// The asset version that produced the database on disk, or 0 when that
  /// cannot be established. An install made before this marker existed is
  /// therefore refreshed once: we have no way of telling which build of the
  /// asset it copied, and a single extra copy is a small price for knowing
  /// exactly what it holds from then on.
  Future<int> _readInstalledDbVersion(String versionPath) async {
    try {
      final File marker = File(versionPath);
      if (!await marker.exists()) return 0;
      return int.tryParse((await marker.readAsString()).trim()) ?? 0;
    } catch (_) {
      // A marker we cannot read is treated as missing, so the database is
      // rebuilt from the asset instead of being trusted on its word.
      return 0;
    }
  }

  /// Unpacks the bundled database over [targetPath] and records the asset
  /// version it came from.
  Future<void> _installAssetDb(String targetPath, String versionPath) async {
    final ByteData data = await rootBundle.load(_assetDbPath);
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    final File target = File(targetPath);
    await target.parent.create(recursive: true);

    // Write the fifty megabytes to a staging file and only then move it into
    // place. Writing straight over the database would, if the process were
    // killed or the disk filled up half way through, leave a truncated file
    // that still looks present and non-empty and would be opened as though
    // it were a real database.
    final File staging = File('$targetPath.new');
    try {
      await staging.writeAsBytes(bytes, flush: true);

      // Drop the marker before disturbing the database. Everything from here
      // on is a fast metadata operation, and an interruption in the middle of
      // them leaves either no database or a complete one, both of which the
      // next open rebuilds because no marker vouches for them.
      await _deleteQuietly(File(versionPath));
      await _deleteQuietly(target);

      // SQLite keeps its rollback journal beside the database. One left over
      // from the previous copy describes pages of a file that no longer
      // exists, so letting SQLite replay it onto the new one would corrupt
      // the very database we just installed.
      for (final String suffix in const <String>['-journal', '-wal', '-shm']) {
        await _deleteQuietly(File('$targetPath$suffix'));
      }

      await staging.rename(targetPath);
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }

    try {
      await File(versionPath).writeAsString('$_assetDbVersion', flush: true);
    } catch (_) {
      // The database itself is in place; a marker that cannot be written
      // only costs a redundant copy next time, which is not worth failing
      // the open over.
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Housekeeping only: a file that cannot be removed must not stop the
      // finder from opening the database we actually use.
    }
  }

  Database _requireDb() {
    final Database? db = _db;
    if (db == null) {
      throw StateError('IrBlasterDb not initialized. Call ensureInitialized() first.');
    }
    return db;
  }

  Future<void> _ensurePerformanceTuning() async {
    if (_perfTuned) return;
    final db = _requireDb();

    Future<void> tryExec(String sql) async {
      try {
        await db.execute(sql);
      } catch (_) {
        // ignore
      }
    }

    await tryExec('PRAGMA temp_store=MEMORY;');
    await tryExec('PRAGMA cache_size=-20000;'); // ~20MB cache (negative => KB pages)
    await tryExec('PRAGMA mmap_size=268435456;'); // 256MB mmap (best-effort)
    await tryExec('PRAGMA synchronous=NORMAL;');
    await tryExec('PRAGMA foreign_keys=OFF;');

    // Core indexes
    await tryExec('CREATE INDEX IF NOT EXISTS idx_keys_protocol_id ON keys(protocol, id);');
    await tryExec('CREATE INDEX IF NOT EXISTS idx_keys_id ON keys(id);');
    await tryExec('CREATE INDEX IF NOT EXISTS idx_models_brand_id ON models(brand, id);');
    await tryExec('CREATE INDEX IF NOT EXISTS idx_models_brand_model ON models(brand, model);');
    await tryExec('CREATE INDEX IF NOT EXISTS idx_brands_name_nocase ON brands(name COLLATE NOCASE);');

    // Helpful optional indexes for case-insensitive / normalized protocol matching:
    await tryExec('CREATE INDEX IF NOT EXISTS idx_keys_protocol_nocase_id ON keys(protocol COLLATE NOCASE, id);');

    // Expression index (best-effort; supported on modern SQLite). If unsupported, it will be ignored.
    await tryExec(
      "CREATE INDEX IF NOT EXISTS idx_keys_protocol_norm_id ON keys("
      "lower(replace(replace(replace(protocol,'-',''),'_',''),' ','')), id"
      ");",
    );

    await tryExec('PRAGMA optimize;');

    _perfTuned = true;
  }

  // ---- Protocol normalization helpers ----

  static String _protocolKey(String s) {
    // Keep only [a-z0-9] after lowercasing; this makes:
    // "RCA-38" == "rca_38" == "RCA 38" -> "rca38"
    return s
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  static String _sqlProtocolNormExpr(String column) {
    // Mirror a subset of _protocolKey() in SQL (fast enough + indexable via expression index).
    // We normalize by removing '-', '_' and spaces and lowercasing.
    return "lower(replace(replace(replace($column,'-',''),'_',''),' ',''))";
  }

  Future<void> _ensureProtocolMapLoaded() async {
    if (_protocolMapLoaded) return;
    final db = _requireDb();

    // Distinct over protocol is usually cheap with idx_keys_protocol_id.
    final rows = await db.rawQuery('SELECT DISTINCT protocol FROM keys WHERE protocol IS NOT NULL;');
    for (final r in rows) {
      final v = r['protocol'];
      if (v == null) continue;
      final String protoStr = v.toString();
      final String key = _protocolKey(protoStr);
      if (key.isEmpty) continue;
      _canonicalProtocolByKey.putIfAbsent(key, () => protoStr);
    }

    _protocolMapLoaded = true;
  }

  Future<_ProtocolFilter?> _resolveProtocolFilter(String? selectedProtocolId) async {
    final String? s = (selectedProtocolId == null || selectedProtocolId.trim().isEmpty)
        ? null
        : selectedProtocolId.trim();
    if (s == null) return null;

    final String key = _protocolKey(s);
    if (key.isEmpty) return null;

    await _ensureProtocolMapLoaded();

    // If DB has a canonical spelling for this normalized key, use it (fast path).
    final String? canonical = _canonicalProtocolByKey[key];

    return _ProtocolFilter(
      normalizedKey: key,
      canonicalDbValue: canonical,
    );
  }

  void _appendProtocolWhere({
    required List<String> where,
    required List<Object?> args,
    required String column,
    required _ProtocolFilter filter,
  }) {
    if (filter.canonicalDbValue != null) {
      // Exact DB value -> uses idx_keys_protocol_id
      where.add('$column = ?');
      args.add(filter.canonicalDbValue);
    } else {
      // Fallback normalized expression (works even if DB uses different separators/case)
      where.add('${_sqlProtocolNormExpr(column)} = ?');
      args.add(filter.normalizedKey);
    }
  }

  // ---- Public API ----

  Future<List<String>> listProtocolsFor({required String brand, required String model}) async {
    await ensureInitialized();
    final db = _requireDb();
    final String b = brand.trim();
    final String m = model.trim();
    if (b.isEmpty || m.isEmpty) return <String>[];

    final rows = await db.rawQuery('''
      SELECT DISTINCT k.protocol AS protocol
      FROM models m
      JOIN keys k ON k.id = m.id
      WHERE m.brand = ? AND m.model = ? AND k.protocol IS NOT NULL
      ORDER BY UPPER(k.protocol) ASC
    ''', [b, m]);
    return rows
        .map((r) => (r['protocol'] as String?)?.trim())
        .whereType<String>()
        .toList(growable: false);
  }

  /// Returns distinct protocols used by [brand] across all its models,
  /// ordered alphabetically. Used to auto-adjust the protocol when a
  /// brand is selected in the IR Finder without a protocol filter.
  Future<List<String>> listProtocolsForBrand(String brand) async {
    await ensureInitialized();
    final db = _requireDb();
    final String b = brand.trim();
    if (b.isEmpty) return <String>[];

    final rows = await db.rawQuery('''
      SELECT DISTINCT k.protocol AS protocol
      FROM models m
      JOIN keys k ON k.id = m.id
      WHERE m.brand = ? AND k.protocol IS NOT NULL
      ORDER BY UPPER(k.protocol) ASC
    ''', [b]);
    return rows
        .map((r) => (r['protocol'] as String?)?.trim())
        .whereType<String>()
        .toList(growable: false);
  }

  Future<List<String>> listBrands({
    String? search,
    String? protocolId,
    int limit = 60,
    int offset = 0,
  }) async {
    await ensureInitialized();
    final db = _requireDb();

    final String? q = (search == null || search.trim().isEmpty) ? null : search.trim();
    final _ProtocolFilter? pf = await _resolveProtocolFilter(protocolId);

    // Always query through models+keys so the returned brand names are
    // exactly the same strings stored in models.brand. This is critical for
    // consistency: listProtocolsForBrand, listModelsDistinct, and the signal
    // test all query models.brand with an exact-match WHERE clause. If we
    // returned brand names from the separate `brands` display table they might
    // differ in capitalisation or spacing (e.g. "O General" vs "O-General"),
    // causing those follow-up queries to return zero results.
    final where = <String>[];
    final args = <Object?>[];

    if (pf != null) {
      _appendProtocolWhere(where: where, args: args, column: 'k.protocol', filter: pf);
    }

    if (q != null) {
      where.add('m.brand LIKE ? ESCAPE \'\\\'');
      args.add('%${_escapeLike(q)}%');
    }

    final String whereSql =
        where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    final sql = '''
      SELECT DISTINCT m.brand AS name
      FROM models m
      JOIN keys k ON k.id = m.id
      $whereSql
      ORDER BY name COLLATE NOCASE ASC
      LIMIT ? OFFSET ?
    ''';

    args.add(limit);
    args.add(offset);

    final rows = await db.rawQuery(sql, args);
    return rows.map((r) => (r['name'] as String)).toList(growable: false);
  }

  Future<List<String>> listModelsDistinct({
    required String brand,
    String? search,
    String? protocolId,
    int limit = 60,
    int offset = 0,
  }) async {
    await ensureInitialized();
    final db = _requireDb();

    final String b = brand.trim();
    if (b.isEmpty) return <String>[];

    final String? q = (search == null || search.trim().isEmpty) ? null : search.trim();
    final _ProtocolFilter? pf = await _resolveProtocolFilter(protocolId);

    // No protocol filter: keep it simple.
    if (pf == null) {
      final where = <String>['brand = ?'];
      final args = <Object?>[b];

      if (q != null) {
        where.add('model LIKE ? ESCAPE \'\\\'');
        args.add('%${_escapeLike(q)}%');
      }

      final rows = await db.query(
        'models',
        columns: const <String>['model'],
        distinct: true,
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'model COLLATE NOCASE ASC',
        limit: limit,
        offset: offset,
      );
      return rows.map((r) => (r['model'] as String)).toList(growable: false);
    }

    // Protocol-filtered models for a brand:
    final where = <String>['m.brand = ?'];
    final args = <Object?>[b];

    _appendProtocolWhere(where: where, args: args, column: 'k.protocol', filter: pf);

    if (q != null) {
      where.add('m.model LIKE ? ESCAPE \'\\\'');
      args.add('%${_escapeLike(q)}%');
    }

    final sql = '''
      SELECT DISTINCT m.model AS model
      FROM models m
      JOIN keys k ON k.id = m.id
      WHERE ${where.join(' AND ')}
      ORDER BY model COLLATE NOCASE ASC
      LIMIT ? OFFSET ?
    ''';

    args.add(limit);
    args.add(offset);

    final rows = await db.rawQuery(sql, args);
    return rows.map((r) => (r['model'] as String)).toList(growable: false);
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
    await ensureInitialized();
    final db = _requireDb();

    final String b = brand.trim();
    if (b.isEmpty) return <IrDbKeyCandidate>[];

    final String? m = (model == null || model.trim().isEmpty) ? null : model.trim();
    final String? prefix = (hexPrefixUpper == null || hexPrefixUpper.trim().isEmpty)
        ? null
        : hexPrefixUpper.replaceAll(RegExp(r'\s+'), '').toUpperCase();

    final _ProtocolFilter? pf = await _resolveProtocolFilter(selectedProtocolId);

    final args = <Object?>[];
    final where = <String>[];

    where.add('m.brand = ?');
    args.add(b);

    if (m != null) {
      where.add('m.model = ?');
      args.add(m);
    }

    if (pf != null) {
      _appendProtocolWhere(where: where, args: args, column: 'k.protocol', filter: pf);
    }

    if (prefix != null) {
      where.add('UPPER(k.hexcode) LIKE ?');
      args.add('$prefix%');
    }

    final String? q = (search == null || search.trim().isEmpty) ? null : _escapeLike(search.trim());
    if (q != null) {
      where.add('(UPPER(k.label) LIKE UPPER(?) ESCAPE \'\\\' OR UPPER(k.hexcode) LIKE UPPER(?))');
      args.add('%$q%');
      args.add('%${q.toUpperCase()}%');
    }

    final String orderBy = quickWinsFirst
        ? '''
 CASE
 WHEN UPPER(k.label) LIKE '%POWER%' OR UPPER(k.label) IN ('PWR','POWER','ON','OFF') THEN 0
 WHEN UPPER(k.label) LIKE '%MUTE%' OR UPPER(k.label) = 'MUTE' THEN 1
 WHEN UPPER(k.label) LIKE 'VOL%' OR UPPER(k.label) LIKE '%VOLUME%' THEN 2
 WHEN UPPER(k.label) LIKE 'CH%' OR UPPER(k.label) LIKE '%CHANNEL%' THEN 3
 WHEN UPPER(k.label) IN ('OK','ENTER','MENU','HOME','BACK','UP','DOWN','LEFT','RIGHT') THEN 4
 ELSE 9
 END ASC,
 UPPER(k.label) ASC,
 UPPER(k.protocol) ASC,
 UPPER(k.hexcode) ASC,
 k.id ASC
 '''
        : '''
 UPPER(k.label) ASC,
 UPPER(k.protocol) ASC,
 UPPER(k.hexcode) ASC,
 k.id ASC
 ''';

    final sql = '''
 SELECT
   k.id AS remote_id,
   k.label AS label,
   k.hexcode AS hexcode,
   k.protocol AS protocol,
   m.brand AS brand,
   m.model AS model
 FROM models m
 JOIN keys k ON k.id = m.id
 WHERE ${where.join(' AND ')}
 ORDER BY $orderBy
 LIMIT ? OFFSET ?
''';

    args.add(limit);
    args.add(offset);

    final rows = await db.rawQuery(sql, args);

    return rows.map((r) {
      final int remoteId = (r['remote_id'] as int);
      final String label = (r['label'] as String);
      final String hex = (r['hexcode'] as String);
      final String protocol = (r['protocol'] as String);
      final String rb = (r['brand'] as String);
      final String rm = (r['model'] as String);

      return IrDbKeyCandidate(
        id: remoteId,
        protocol: protocol,
        hexcode: hex,
        remoteId: remoteId,
        label: label,
        brand: rb,
        model: rm,
      );
    }).toList(growable: false);
  }

  Future<int> countCandidateKeys({
    required String brand,
    String? model,
    String? selectedProtocolId,
    String? hexPrefixUpper,
    String? search,
  }) async {
    await ensureInitialized();
    final db = _requireDb();

    final String b = brand.trim();
    if (b.isEmpty) return 0;

    final String? m = (model == null || model.trim().isEmpty) ? null : model.trim();
    final String? prefix = (hexPrefixUpper == null || hexPrefixUpper.trim().isEmpty)
        ? null
        : hexPrefixUpper.replaceAll(RegExp(r'\s+'), '').toUpperCase();

    final _ProtocolFilter? pf = await _resolveProtocolFilter(selectedProtocolId);

    final args = <Object?>[];
    final where = <String>[];

    where.add('m.brand = ?');
    args.add(b);

    if (m != null) {
      where.add('m.model = ?');
      args.add(m);
    }

    if (pf != null) {
      _appendProtocolWhere(where: where, args: args, column: 'k.protocol', filter: pf);
    }

    if (prefix != null) {
      where.add('UPPER(k.hexcode) LIKE ?');
      args.add('$prefix%');
    }

    final String? q = (search == null || search.trim().isEmpty) ? null : _escapeLike(search.trim());
    if (q != null) {
      where.add('(UPPER(k.label) LIKE UPPER(?) ESCAPE \'\\\' OR UPPER(k.hexcode) LIKE UPPER(?))');
      args.add('%$q%');
      args.add('%${q.toUpperCase()}%');
    }

    final sql = '''
 SELECT COUNT(1) AS cnt
 FROM models m
 JOIN keys k ON k.id = m.id
 WHERE ${where.join(' AND ')}
''';

    final rows = await db.rawQuery(sql, args);
    if (rows.isEmpty) return 0;
    final dynamic v = rows.first['cnt'];
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  static String _escapeLike(String input) {
    return input.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
  }
}

class _ProtocolFilter {
  final String normalizedKey;
  final String? canonicalDbValue;
  const _ProtocolFilter({
    required this.normalizedKey,
    required this.canonicalDbValue,
  });
}
