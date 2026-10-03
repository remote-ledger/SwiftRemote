import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:swiftremote/ledger_db/ledger_cache.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';

/// Where the Remote Ledger publishes the IR code database: static files under
/// the ledger's GitHub Pages site, version 1 of its app API.
const String kLedgerApiBaseUrl = 'https://remote-ledger.github.io/app/v1/';

/// Files larger than this are parsed on another isolate; below it, the hop
/// costs more than the parse.
const int kLedgerOffloadBytes = 128 * 1024;

/// Runs [computation], on another isolate when [weight] (the size of what it
/// parses) says it is worth the hop. [computation] must capture only data that
/// can be sent between isolates.
typedef LedgerRunner = Future<R> Function<R>(
  R Function() computation, {
  int weight,
});

/// The runner the app uses.
Future<R> runOffloaded<R>(R Function() computation, {int weight = 0}) {
  if (weight < kLedgerOffloadBytes) return Future<R>.sync(computation);
  return Isolate.run<R>(computation);
}

/// A runner that never leaves the calling isolate (tests, small inputs).
Future<R> runInline<R>(R Function() computation, {int weight = 0}) =>
    Future<R>.sync(computation);

/// A brand's models and keys together.
class LedgerBrandData {
  const LedgerBrandData({required this.models, required this.keys});
  final LedgerBrandModels models;
  final LedgerBrandKeys keys;
}

/// The Remote Ledger's IR code database, read online and kept on the device.
///
/// What it does, and what it leaves to its callers:
///
/// * Reads `manifest.json` and refuses a schema version it does not know. The
///   manifest is looked at on the network at most every [manifestMaxAge];
///   between checks the copy on the device stands.
/// * Fetches the other files lazily, one request each, and keeps them under
///   the application support directory. A file is used from the device while
///   the manifest's `dataVersion` is the one it was fetched under. When the
///   `dataVersion` moves on, `brands.json`, a brand's models, a signal shard
///   and the power list are fetched again (small files); a brand's key file
///   only when its models file names a different hash for it.
/// * Checks a key file against the hash its models file gives. A file that
///   disagrees is rejected and fetched once more; if it still disagrees it is
///   not used (and not cached).
/// * Uses any copy it has when the network fails. [LedgerDbUnavailable] means
///   there is no copy.
/// * Parses large files on another isolate.
///
/// It knows nothing of the app's queries; see `IrBlasterDb`.
class LedgerDb {
  LedgerDb({
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? now,
    this.baseUrl = kLedgerApiBaseUrl,
    this.manifestMaxAge = const Duration(hours: 12),
    this.manifestRetryAfterFailure = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 30),
    this.manifestRefreshTimeout = const Duration(seconds: 8),
    this.maxCacheBytes = 40 * 1024 * 1024,
    LedgerRunner? runner,
  })  : _client = client,
        _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
        _now = now ?? DateTime.now,
        _run = runner ?? runOffloaded;

  final String baseUrl;
  final Duration manifestMaxAge;
  final Duration manifestRetryAfterFailure;
  final Duration requestTimeout;

  /// How long a look-up of the manifest that only refreshes a copy already on
  /// the device may take: someone offline should not wait half a minute to
  /// find that out.
  final Duration manifestRefreshTimeout;
  final int maxCacheBytes;

  http.Client? _client;
  final Future<Directory> Function() _cacheDirectory;
  final DateTime Function() _now;
  final LedgerRunner _run;

  static Future<Directory> _defaultCacheDirectory() async {
    final Directory support = await getApplicationSupportDirectory();
    return Directory('${support.path}/irdb/v1');
  }

  // ---- the device copy ----

  Future<LedgerCache?>? _cacheFuture;
  _Meta _meta = _Meta();
  Timer? _metaTimer;
  bool _metaDirty = false;

  Future<LedgerCache?> _cacheOrNull() {
    return _cacheFuture ??= () async {
      try {
        final Directory dir = await _cacheDirectory();
        await dir.create(recursive: true);
        final LedgerCache cache =
            LedgerCache(dir, maxBytes: maxCacheBytes, now: _now);
        await cache.removeStaging();
        final Uint8List? raw = await cache.read('meta.json');
        if (raw != null) {
          try {
            _meta = _Meta.fromJson(jsonDecode(utf8.decode(raw)));
          } catch (_) {
            _meta = _Meta();
          }
        }
        return cache;
      } catch (_) {
        // No directory to keep files in: the database still works, from the
        // network, for as long as the process lives.
        return null;
      }
    }();
  }

  void _metaChanged() {
    _metaDirty = true;
    _metaTimer ??= Timer(const Duration(seconds: 2), () {
      _metaTimer = null;
      unawaited(flush());
    });
  }

  /// Writes what the device copy knows about its own files (which
  /// `dataVersion` each was fetched under) to disk. Called on its own a moment
  /// after a change; a process that dies first only costs a re-fetch.
  Future<void> flush() async {
    _metaTimer?.cancel();
    _metaTimer = null;
    if (!_metaDirty) return;
    _metaDirty = false;
    final LedgerCache? cache = await _cacheOrNull();
    if (cache == null) return;
    await cache.write(
      'meta.json',
      Uint8List.fromList(utf8.encode(jsonEncode(_meta.toJson()))),
    );
  }

  // ---- the network ----

  final Map<String, Future<Uint8List>> _inflight =
      <String, Future<Uint8List>>{};

  Future<Uint8List> _get(String path, {Duration? timeout}) {
    final Future<Uint8List>? running = _inflight[path];
    if (running != null) return running;
    final Future<Uint8List> f = _fetch(path, timeout ?? requestTimeout);
    _inflight[path] = f;
    // Block bodies: `remove` returns the very future that may have failed,
    // and a callback that returns it would make this chain fail with it.
    unawaited(f.then<void>(
      (_) {
        _inflight.remove(path);
      },
      onError: (Object _) {
        _inflight.remove(path);
      },
    ));
    return f;
  }

  Future<Uint8List> _fetch(String path, Duration timeout) async {
    final Uri uri = Uri.parse('$baseUrl$path');
    try {
      final http.Response response =
          await (_client ??= http.Client()).get(uri).timeout(timeout);
      if (response.statusCode != 200) {
        throw LedgerDbUnavailable(
          LedgerDbFailure.server,
          'The server answered HTTP ${response.statusCode} for $path.',
        );
      }
      return response.bodyBytes;
    } on LedgerDbUnavailable {
      rethrow;
    } on TimeoutException catch (e) {
      throw LedgerDbUnavailable(
        LedgerDbFailure.offline,
        'Timed out fetching $path.',
        cause: e,
      );
    } catch (e) {
      throw LedgerDbUnavailable(
        LedgerDbFailure.offline,
        'Could not fetch $path: $e',
        cause: e,
      );
    }
  }

  Future<T> _parse<T>(T Function(Uint8List) parse, Uint8List bytes) async {
    try {
      return await _runParse<T>(_run, parse, bytes);
    } on LedgerDbUnavailable {
      rethrow;
    } catch (e) {
      throw LedgerDbUnavailable(
        LedgerDbFailure.corrupt,
        'A file of the IR code database could not be read: $e',
        cause: e,
      );
    }
  }

  // ---- the manifest ----

  LedgerManifest? _manifest;
  DateTime? _manifestAt;
  DateTime? _nextManifestAttempt;
  Future<LedgerManifest>? _manifestFuture;

  /// The `dataVersion` of the manifest in use, or null before it was read.
  String? get dataVersion => _manifest?.dataVersion;

  /// The manifest, from memory, the device or the network in that order.
  ///
  /// With [refresh] (the default) a manifest older than [manifestMaxAge] is
  /// looked up again; a failed look-up keeps the copy that is there and is
  /// not repeated for [manifestRetryAfterFailure]. Without it, whatever is
  /// already in memory is returned without any look-up at all, which is what
  /// a loop that must not touch the network wants.
  Future<LedgerManifest> manifest({bool refresh = true}) {
    final LedgerManifest? memory = _manifest;
    final DateTime? at = _manifestAt;
    if (memory != null && at != null) {
      if (!refresh || _now().difference(at) < manifestMaxAge) {
        return Future<LedgerManifest>.value(memory);
      }
    }
    return _manifestFuture ??=
        _loadManifest().whenComplete(() => _manifestFuture = null);
  }

  Future<LedgerManifest> _loadManifest() async {
    final LedgerCache? cache = await _cacheOrNull();

    LedgerManifest? cached;
    if (cache != null) {
      final Uint8List? raw = await cache.read('manifest.json');
      if (raw != null) {
        try {
          cached = LedgerManifest.parse(raw);
        } catch (_) {
          // A copy this build cannot read, or a broken one: as good as none.
          cached = null;
        }
      }
    }
    final LedgerManifest? memory = _manifest;
    if (cached == null && memory != null) cached = memory;

    final int? checkedMs = _meta.manifestCheckedAtMs;
    final DateTime? checked = checkedMs == null
        ? _manifestAt
        : DateTime.fromMillisecondsSinceEpoch(checkedMs);
    if (cached != null && checked != null) {
      final bool fresh = _now().difference(checked) < manifestMaxAge;
      final DateTime? retryAt = _nextManifestAttempt;
      final bool backingOff = retryAt != null && _now().isBefore(retryAt);
      if (fresh || backingOff) {
        return _remember(cached, checked);
      }
    }

    try {
      final Uint8List bytes = await _get(
        'manifest.json',
        timeout: cached != null ? manifestRefreshTimeout : requestTimeout,
      );
      final LedgerManifest fetched;
      try {
        fetched = LedgerManifest.parse(bytes);
      } on LedgerDbUnavailable {
        rethrow;
      } catch (e) {
        throw LedgerDbUnavailable(
          LedgerDbFailure.corrupt,
          'The manifest could not be read: $e',
          cause: e,
        );
      }
      final DateTime now = _now();
      _meta.manifestCheckedAtMs = now.millisecondsSinceEpoch;
      _nextManifestAttempt = null;
      if (cache != null) {
        await cache.write('manifest.json', bytes);
      }
      _metaChanged();
      return _remember(fetched, now);
    } on LedgerDbUnavailable {
      if (cached != null) {
        _nextManifestAttempt = _now().add(manifestRetryAfterFailure);
        return _remember(cached, checked ?? _now());
      }
      rethrow;
    }
  }

  LedgerManifest _remember(LedgerManifest m, DateTime checkedAt) {
    if (_memoryVersion != null && _memoryVersion != m.dataVersion) {
      _brandsMemory = null;
      _modelsMemory.clear();
      _brandDataMemory.clear();
      _shardMemory.clear();
      _powerMemory = null;
    }
    _memoryVersion = m.dataVersion;
    _manifest = m;
    _manifestAt = checkedAt;
    return m;
  }

  // ---- versioned files ----

  String? _memoryVersion;

  /// Loads [path] and parses it. The device copy is used while it was fetched
  /// under the manifest's `dataVersion`; otherwise the file is fetched, parsed,
  /// and stored, and if that fails the stale copy, when there is one, stands
  /// in.
  Future<T> _loadVersioned<T>(
    String path,
    LedgerManifest manifest,
    T Function(Uint8List) parse,
  ) async {
    final LedgerCache? cache = await _cacheOrNull();
    Uint8List? cached = await cache?.read(path);
    if (cached != null && _meta.dv[path] == manifest.dataVersion) {
      try {
        return await _parse<T>(parse, cached);
      } on LedgerDbUnavailable {
        await cache!.delete(path);
        _meta.dv.remove(path);
        cached = null;
      }
    }
    try {
      final Uint8List bytes = await _get(path);
      final T value = await _parse<T>(parse, bytes);
      if (cache != null && await cache.write(path, bytes)) {
        _meta.dv[path] = manifest.dataVersion;
        _metaChanged();
      }
      return value;
    } on LedgerDbUnavailable {
      if (cached != null) {
        try {
          return await _parse<T>(parse, cached);
        } on LedgerDbUnavailable {
          // Nothing usable on the device either.
        }
      }
      rethrow;
    }
  }

  // ---- the files ----

  List<LedgerBrand>? _brandsMemory;

  /// `brands.json`: every brand, in `COLLATE NOCASE` order.
  Future<List<LedgerBrand>> brands() {
    return _once<List<LedgerBrand>>('brands', () async {
      final LedgerManifest m = await manifest(refresh: false);
      final List<LedgerBrand>? memory = _brandsMemory;
      if (memory != null) return memory;
      final List<LedgerBrand> loaded =
          await _loadVersioned(m.brandsPath, m, parseBrands);
      return _brandsMemory = loaded;
    });
  }

  final Map<String, LedgerBrandModels> _modelsMemory =
      <String, LedgerBrandModels>{};

  /// A brand's models and ids (`b/<key>.m.json`), which is small.
  Future<LedgerBrandModels> brandModels(String key) {
    _checkKey(key);
    return _once<LedgerBrandModels>('models:$key', () async {
      final LedgerManifest m = await manifest(refresh: false);
      final LedgerBrandModels? memory = _modelsMemory.remove(key);
      if (memory != null) {
        return _modelsMemory[key] = memory;
      }
      final LedgerBrandModels loaded = await _loadVersioned(
        m.brandModelsPath(key),
        m,
        LedgerBrandModels.parse,
      );
      _modelsMemory[key] = loaded;
      while (_modelsMemory.length > 8) {
        _modelsMemory.remove(_modelsMemory.keys.first);
      }
      return loaded;
    });
  }

  final Map<String, LedgerBrandData> _brandDataMemory =
      <String, LedgerBrandData>{};

  /// A brand's models and every key (`b/<key>.k.json`, which for a large brand
  /// is megabytes), checked against the hash its models file gives.
  Future<LedgerBrandData> brand(String key) {
    _checkKey(key);
    return _once<LedgerBrandData>('brand:$key', () async {
      final LedgerManifest m = await manifest(refresh: false);
      final LedgerBrandData? memory = _brandDataMemory.remove(key);
      if (memory != null) {
        return _brandDataMemory[key] = memory;
      }
      final LedgerBrandModels models = await brandModels(key);
      final LedgerBrandKeys keys =
          await _loadBrandKeys(m.brandKeysPath(key), models.hash);
      final LedgerBrandData data = LedgerBrandData(models: models, keys: keys);
      _brandDataMemory[key] = data;
      while (_brandDataMemory.length > 3) {
        _brandDataMemory.remove(_brandDataMemory.keys.first);
      }
      return data;
    });
  }

  Future<LedgerBrandKeys> _loadBrandKeys(String path, String hash) async {
    final LedgerCache? cache = await _cacheOrNull();
    Uint8List? stale = await cache?.read(path);

    if (stale != null) {
      final bool matches = _meta.sha[path] == hash || _sha(stale, hash);
      if (matches) {
        try {
          final LedgerBrandKeys keys =
              await _parse<LedgerBrandKeys>(LedgerBrandKeys.parse, stale);
          if (_meta.sha[path] != hash) {
            _meta.sha[path] = hash;
            _metaChanged();
          }
          return keys;
        } on LedgerDbUnavailable {
          await cache!.delete(path);
          _meta.sha.remove(path);
          stale = null;
        }
      }
    }

    LedgerDbUnavailable? failure;
    Uint8List? good;
    for (int attempt = 0; attempt < 2 && good == null; attempt++) {
      try {
        final Uint8List bytes = await _get(path);
        if (_sha(bytes, hash)) {
          good = bytes;
        } else {
          failure = LedgerDbUnavailable(
            LedgerDbFailure.server,
            '$path does not match the hash its brand gives ($hash).',
          );
        }
      } on LedgerDbUnavailable catch (e) {
        failure = e;
        break;
      }
    }

    if (good != null) {
      final LedgerBrandKeys keys =
          await _parse<LedgerBrandKeys>(LedgerBrandKeys.parse, good);
      if (cache != null && await cache.write(path, good)) {
        _meta.sha[path] = hash;
        _metaChanged();
      }
      return keys;
    }

    // The network did not deliver a file that matches. A copy from before
    // the brand changed is still the brand's keys, as of an earlier day.
    if (stale != null) {
      try {
        return await _parse<LedgerBrandKeys>(LedgerBrandKeys.parse, stale);
      } on LedgerDbUnavailable {
        // fall through
      }
    }
    throw failure ??
        const LedgerDbUnavailable(
          LedgerDbFailure.server,
          'A brand file could not be loaded.',
        );
  }

  bool _sha(Uint8List bytes, String hash) =>
      sha256.convert(bytes).toString().startsWith(hash);

  final Map<String, LedgerSignalShard> _shardMemory =
      <String, LedgerSignalShard>{};

  /// The compiled signals of one database protocol (`s/<protocol>.json`).
  /// Only protocols whose `appReadingDiffers` is set have one.
  Future<LedgerSignalShard> signalShard(String dbProtocol) {
    _checkKey(dbProtocol);
    return _once<LedgerSignalShard>('shard:$dbProtocol', () async {
      final LedgerManifest m = await manifest(refresh: false);
      final LedgerSignalShard? memory = _shardMemory[dbProtocol];
      if (memory != null) return memory;
      final LedgerSignalShard loaded = await _loadVersioned(
        m.signalsPath(dbProtocol),
        m,
        LedgerSignalShard.parse,
      );
      if (loaded.protocol != dbProtocol) {
        throw LedgerDbUnavailable(
          LedgerDbFailure.corrupt,
          's/$dbProtocol.json holds the signals of ${loaded.protocol}.',
        );
      }
      return _shardMemory[dbProtocol] = loaded;
    });
  }

  List<LedgerPowerRow>? _powerMemory;

  /// `power.json`: the codes whose label ranks as power, most used first.
  Future<List<LedgerPowerRow>> power() {
    return _once<List<LedgerPowerRow>>('power', () async {
      final LedgerManifest m = await manifest(refresh: false);
      final List<LedgerPowerRow>? memory = _powerMemory;
      if (memory != null) return memory;
      final List<LedgerPowerRow> loaded =
          await _loadVersioned(m.powerPath, m, parsePower);
      return _powerMemory = loaded;
    });
  }

  // ---- plumbing ----

  final Map<String, Future<Object?>> _pending = <String, Future<Object?>>{};

  /// One load of [key] at a time: a second caller gets the first's result.
  Future<T> _once<T>(String key, Future<T> Function() make) {
    final Future<Object?>? running = _pending[key];
    if (running != null) return running as Future<T>;
    final Future<T> f = make();
    _pending[key] = f;
    unawaited(f.then<void>(
      (_) {
        _pending.remove(key);
      },
      onError: (Object _) {
        _pending.remove(key);
      },
    ));
    return f;
  }

  static final RegExp _safeName = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_\-]*$');

  void _checkKey(String key) {
    if (!_safeName.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Not a file name of the database');
    }
  }

  /// Closes the HTTP client. The database cannot be used afterwards.
  void close() {
    _metaTimer?.cancel();
    _client?.close();
  }
}

/// A top-level function, so the closure handed to the runner captures only
/// [parse] and [bytes] and not the database object, which cannot be sent to
/// another isolate.
Future<T> _runParse<T>(
  LedgerRunner run,
  T Function(Uint8List) parse,
  Uint8List bytes,
) {
  return run<T>(() => parse(bytes), weight: bytes.length);
}

/// What the device copy knows about its own files.
class _Meta {
  _Meta();

  int? manifestCheckedAtMs;

  /// The `dataVersion` each file was fetched under.
  final Map<String, String> dv = <String, String>{};

  /// The hash each cached key file was verified against.
  final Map<String, String> sha = <String, String>{};

  factory _Meta.fromJson(dynamic json) {
    final _Meta meta = _Meta();
    if (json is! Map) return meta;
    if (json['v'] != 1) return meta;
    final dynamic checked = json['manifestCheckedAtMs'];
    if (checked is int) meta.manifestCheckedAtMs = checked;
    final dynamic dv = json['dv'];
    if (dv is Map) {
      for (final MapEntry<dynamic, dynamic> e in dv.entries) {
        if (e.key is String && e.value is String) {
          meta.dv[e.key as String] = e.value as String;
        }
      }
    }
    final dynamic sha = json['sha'];
    if (sha is Map) {
      for (final MapEntry<dynamic, dynamic> e in sha.entries) {
        if (e.key is String && e.value is String) {
          meta.sha[e.key as String] = e.value as String;
        }
      }
    }
    return meta;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': 1,
        'manifestCheckedAtMs': manifestCheckedAtMs,
        'dv': dv,
        'sha': sha,
      };
}
