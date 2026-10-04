import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// The one repository the app takes remotes from: Remote Ledger's, on its
/// default branch. It is written here and nowhere else, so no setting, link or
/// saved preference can point the app at another source.
const String kRemoteLedgerOwner = 'remote-ledger';
const String kRemoteLedgerRepo = 'remote-ledger.github.io';
const String kRemoteLedgerBranch = 'master';

/// The folder the ledger browser opens on. It holds the compiled remotes: one
/// JSON file per remote, each key's most trusted code already rendered to
/// Pronto Hex. The source files under `remotes/` hold the same codes before
/// compiling, which the importer cannot play, so the browser stays on the
/// folder that it can.
const String kRemoteLedgerBrowseRoot = 'build/pronto';

class GitHubRateLimitException implements Exception {
  final String message;
  final DateTime? resetAt;

  const GitHubRateLimitException(this.message, {this.resetAt});

  @override
  String toString() => message;
}

class _MemoryCacheEntry<T> {
  const _MemoryCacheEntry({
    required this.value,
    required this.savedAt,
  });

  final T value;
  final DateTime savedAt;

  bool isFresh(Duration ttl) => DateTime.now().difference(savedAt) <= ttl;
}

/// Reads folders and files of the Remote Ledger repository through GitHub's
/// contents API, without credentials. [client] is for tests.
class GitHubStoreService {
  GitHubStoreService({http.Client? client}) : _client = client ?? http.Client();

  static const String userAgent = 'IRBlaster/1.0';
  static const int maxPreviewBytes = 512 * 1024;
  static const int _directoryCacheVersion = 2;
  static const Duration _directoryCacheTtl = Duration(minutes: 15);
  static const Duration _fileCacheTtl = Duration(hours: 6);
  static const int _maxPersistedFileCacheBytes = 128 * 1024;
  static const String _directoryIndexKey = 'irblaster.github.cache.dir.index';
  static const String _fileIndexKey = 'irblaster.github.cache.file.index';
  static const String _directoryKeyPrefix = 'irblaster.github.cache.dir.';
  static const String _fileKeyPrefix = 'irblaster.github.cache.file.';
  static const int _maxDirectoryCacheEntries = 48;
  static const int _maxFileCacheEntries = 24;

  final http.Client _client;

  final Map<String, _MemoryCacheEntry<List<RepoItem>>> _directoryMemoryCache =
      <String, _MemoryCacheEntry<List<RepoItem>>>{};
  final Map<String, _MemoryCacheEntry<GitHubFilePayload>> _fileMemoryCache =
      <String, _MemoryCacheEntry<GitHubFilePayload>>{};

  /// The folder at [path], from the repository root.
  Future<List<RepoItem>> listDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'dir:v$_directoryCacheVersion|$path';

    final memory = _directoryMemoryCache[cacheKey];
    if (!forceRefresh && memory != null && memory.isFresh(_directoryCacheTtl)) {
      return memory.value;
    }

    final local =
        await _readDirectoryCache(cacheKey, allowStale: forceRefresh == false);
    if (!forceRefresh && local != null && local.isFresh(_directoryCacheTtl)) {
      _directoryMemoryCache[cacheKey] = local;
      return local.value;
    }

    try {
      final res = await _get(_contentsUri(path));
      final body = jsonDecode(res.body);
      if (body is! List) {
        throw Exception('Expected a directory listing.');
      }

      final items = body
          .map<RepoItem>((entry) {
            final type =
                (entry['type'] == 'dir') ? RepoItemType.dir : RepoItemType.file;
            return RepoItem(
              type: type,
              name: (entry['name'] ?? '').toString(),
              path: (entry['path'] ?? '').toString(),
              size: entry['size'] is int ? entry['size'] as int : null,
              downloadUrl: (entry['download_url'] ?? '').toString().isEmpty
                  ? null
                  : (entry['download_url'] as String),
              sha: (entry['sha'] ?? '').toString().isEmpty
                  ? null
                  : (entry['sha'] as String),
            );
          })
          .where(
            (item) => item.name.isNotEmpty && !item.name.startsWith('.'),
          )
          .toList()
        ..sort((a, b) {
          if (a.type != b.type) {
            return a.type == RepoItemType.dir ? -1 : 1;
          }
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

      await _storeDirectoryCache(cacheKey, items);
      return items;
    } catch (error) {
      if (local != null) {
        _directoryMemoryCache[cacheKey] = local;
        return local.value;
      }
      if (memory != null) {
        return memory.value;
      }
      rethrow;
    }
  }

  /// The file at [fullPath], from the repository root.
  Future<GitHubFilePayload> fetchFileText(
    String fullPath, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'file|$fullPath';

    final memory = _fileMemoryCache[cacheKey];
    if (!forceRefresh && memory != null && memory.isFresh(_fileCacheTtl)) {
      return memory.value;
    }

    final local =
        await _readFileCache(cacheKey, allowStale: forceRefresh == false);
    if (!forceRefresh && local != null && local.isFresh(_fileCacheTtl)) {
      _fileMemoryCache[cacheKey] = local;
      return local.value;
    }

    try {
      final res = await _get(_contentsUri(fullPath));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final size = body['size'] is int ? body['size'] as int : 0;
      if (size > maxPreviewBytes) {
        throw Exception('File is too large to import (max 512 KB).');
      }

      String text;
      if (body['encoding'] == 'base64' && body['content'] is String) {
        final b64 = (body['content'] as String).replaceAll('\n', '');
        text = utf8.decode(base64.decode(b64), allowMalformed: true);
      } else if (body['download_url'] is String) {
        final raw = await _get(
          Uri.parse(body['download_url'] as String),
          acceptJson: false,
        );
        text = raw.body;
      } else {
        throw Exception('No readable file content was returned.');
      }

      final payload = GitHubFilePayload(
        name: (body['name'] ?? '').toString(),
        path: fullPath,
        size: size,
        text: text,
      );
      await _storeFileCache(cacheKey, payload);
      return payload;
    } catch (error) {
      if (local != null) {
        _fileMemoryCache[cacheKey] = local;
        return local.value;
      }
      if (memory != null) {
        return memory.value;
      }
      rethrow;
    }
  }

  Uri _contentsUri(String path) {
    return Uri.https(
      'api.github.com',
      '/repos/$kRemoteLedgerOwner/$kRemoteLedgerRepo/contents/$path',
      <String, String>{'ref': kRemoteLedgerBranch},
    );
  }

  Future<http.Response> _get(
    Uri uri, {
    bool acceptJson = true,
  }) async {
    late final http.Response res;
    try {
      res = await _client.get(
        uri,
        headers: _headers(acceptJson: acceptJson),
      );
    } on SocketException {
      throw Exception(
        'Network error while contacting GitHub. Check connectivity. If you just added the INTERNET permission, fully reinstall/rebuild the app because hot reload does not update Android permissions.',
      );
    } catch (error) {
      throw Exception(error.toString());
    }

    if (res.statusCode == 404) {
      throw Exception('Repository, branch, folder, or file not found.');
    }
    if (res.statusCode == 403) {
      final reset = res.headers['x-ratelimit-reset'];
      DateTime? resetAt;
      if (reset != null) {
        final epoch = int.tryParse(reset);
        if (epoch != null) {
          resetAt = DateTime.fromMillisecondsSinceEpoch(
            epoch * 1000,
            isUtc: true,
          );
        }
      }
      throw GitHubRateLimitException(
        'GitHub API rate limit reached.',
        resetAt: resetAt,
      );
    }
    if (res.statusCode != 200) {
      throw Exception('GitHub returned ${res.statusCode}.');
    }

    return res;
  }

  Map<String, String> _headers({required bool acceptJson}) {
    return <String, String>{
      if (acceptJson) 'Accept': 'application/vnd.github+json',
      'User-Agent': userAgent,
    };
  }

  Future<_MemoryCacheEntry<List<RepoItem>>?> _readDirectoryCache(
    String rawKey, {
    bool allowStale = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheStorageKey(_directoryKeyPrefix, rawKey));
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final savedAtMs = decoded['savedAt'] as int?;
      final itemsRaw = decoded['items'];
      if (savedAtMs == null || itemsRaw is! List) return null;

      final entry = _MemoryCacheEntry<List<RepoItem>>(
        value: itemsRaw
            .whereType<Map>()
            .map(
              (item) => RepoItem(
                type: (item['type'] == 'dir')
                    ? RepoItemType.dir
                    : RepoItemType.file,
                name: (item['name'] ?? '').toString(),
                path: (item['path'] ?? '').toString(),
                size: item['size'] is int ? item['size'] as int : null,
                downloadUrl: (item['downloadUrl'] ?? '').toString().isEmpty
                    ? null
                    : (item['downloadUrl'] as String),
                sha: (item['sha'] ?? '').toString().isEmpty
                    ? null
                    : (item['sha'] as String),
              ),
            )
            .toList(growable: false),
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      );

      if (!allowStale && !entry.isFresh(_directoryCacheTtl)) {
        return null;
      }
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeDirectoryCache(
    String rawKey,
    List<RepoItem> items,
  ) async {
    final entry = _MemoryCacheEntry<List<RepoItem>>(
      value: items,
      savedAt: DateTime.now(),
    );
    _directoryMemoryCache[rawKey] = entry;

    final prefs = await SharedPreferences.getInstance();
    final storageKey = _cacheStorageKey(_directoryKeyPrefix, rawKey);
    await prefs.setString(
      storageKey,
      jsonEncode(<String, dynamic>{
        'savedAt': entry.savedAt.millisecondsSinceEpoch,
        'items': items
            .map(
              (item) => <String, dynamic>{
                'type': item.type == RepoItemType.dir ? 'dir' : 'file',
                'name': item.name,
                'path': item.path,
                if (item.size != null) 'size': item.size,
                if (item.downloadUrl != null) 'downloadUrl': item.downloadUrl,
                if (item.sha != null) 'sha': item.sha,
              },
            )
            .toList(growable: false),
      }),
    );
    await _touchIndex(
      prefs,
      indexKey: _directoryIndexKey,
      storageKey: storageKey,
      maxEntries: _maxDirectoryCacheEntries,
    );
  }

  Future<_MemoryCacheEntry<GitHubFilePayload>?> _readFileCache(
    String rawKey, {
    bool allowStale = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheStorageKey(_fileKeyPrefix, rawKey));
    if (raw == null || raw.trim().isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final savedAtMs = decoded['savedAt'] as int?;
      if (savedAtMs == null) return null;

      final entry = _MemoryCacheEntry<GitHubFilePayload>(
        value: GitHubFilePayload(
          name: (decoded['name'] ?? '').toString(),
          path: (decoded['path'] ?? '').toString(),
          size: decoded['size'] is int ? decoded['size'] as int : 0,
          text: (decoded['text'] ?? '').toString(),
        ),
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMs),
      );

      if (!allowStale && !entry.isFresh(_fileCacheTtl)) {
        return null;
      }
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeFileCache(
    String rawKey,
    GitHubFilePayload payload,
  ) async {
    final entry = _MemoryCacheEntry<GitHubFilePayload>(
      value: payload,
      savedAt: DateTime.now(),
    );
    _fileMemoryCache[rawKey] = entry;
    if (payload.text.length > _maxPersistedFileCacheBytes) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final storageKey = _cacheStorageKey(_fileKeyPrefix, rawKey);
    await prefs.setString(
      storageKey,
      jsonEncode(<String, dynamic>{
        'savedAt': entry.savedAt.millisecondsSinceEpoch,
        'name': payload.name,
        'path': payload.path,
        'size': payload.size,
        'text': payload.text,
      }),
    );
    await _touchIndex(
      prefs,
      indexKey: _fileIndexKey,
      storageKey: storageKey,
      maxEntries: _maxFileCacheEntries,
    );
  }

  String _cacheStorageKey(String prefix, String rawKey) {
    final encoded = base64Url.encode(utf8.encode(rawKey));
    return '$prefix$encoded';
  }

  Future<void> _touchIndex(
    SharedPreferences prefs, {
    required String indexKey,
    required String storageKey,
    required int maxEntries,
  }) async {
    final current = prefs.getStringList(indexKey) ?? const <String>[];
    final next = <String>[
      storageKey,
      ...current.where((key) => key != storageKey),
    ];
    if (next.length > maxEntries) {
      final overflow = next.sublist(maxEntries);
      for (final key in overflow) {
        await prefs.remove(key);
      }
    }
    await prefs.setStringList(
      indexKey,
      next.take(maxEntries).toList(growable: false),
    );
  }
}
