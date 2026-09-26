import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Remote Ledger publishes one index of every remote it holds, beside its
/// site. The GitHub Store searches it rather than the repository: the contents
/// API can only list one folder at a time, and a remote's folder names the
/// remote's model, not the devices it controls, which is what people search
/// for.
const String kRemoteLedgerIndexUrl = 'https://remote-ledger.github.io/index.json';

/// One remote in the index. [artifact] is its compiled file's path from the
/// repository root, ready for the store to open.
class RemoteLedgerEntry {
  const RemoteLedgerEntry({
    required this.manufacturer,
    required this.model,
    required this.artifact,
    this.aliases = const <String>[],
    this.controls = const <String>[],
    this.keyCount = 0,
    this.confidence,
    this.protocol,
    this.importedFrom,
  });

  final String manufacturer;
  final String model;
  final String artifact;
  final List<String> aliases;

  /// The devices this remote controls, e.g. a Sony BDP-S185 for the
  /// RMT-B118P.
  final List<String> controls;
  final int keyCount;
  final String? confidence;
  final String? protocol;

  /// Where a remote imported in bulk came from, e.g. `remotes/lirc/`. Null
  /// for a remote authored in the ledger and checked against independent
  /// sources.
  final String? importedFrom;

  String get title => '$manufacturer $model'.trim();

  /// The artifact's file name, which is what the import preview shows.
  String get fileName => artifact.split('/').last;

  static RemoteLedgerEntry? fromJson(Map<dynamic, dynamic> json) {
    final String artifact = _string(json['artifact']) ?? '';
    if (artifact.isEmpty) return null;
    final dynamic keyCount = json['keyCount'];
    return RemoteLedgerEntry(
      manufacturer: _string(json['manufacturer']) ?? '',
      model: _string(json['model']) ?? '',
      artifact: artifact,
      aliases: _strings(json['aliases']),
      controls: _strings(json['controls']),
      keyCount: keyCount is int ? keyCount : 0,
      confidence: _string(json['confidence']),
      protocol: _string(json['protocol']),
      importedFrom: _string(json['importedFrom']),
    );
  }

  List<String> get _searchFields => <String>[
        manufacturer,
        model,
        ...aliases,
        ...controls,
      ];
}

/// A device someone looked up and recorded as having no known remote. The
/// ledger keeps these so that "nothing found" can say someone checked, rather
/// than meaning nobody has looked yet.
class RemoteLedgerUnresolved {
  const RemoteLedgerUnresolved({required this.device, this.checked});

  final String device;

  /// The date it was checked, as the index writes it (`2026-09-24`).
  final String? checked;

  static RemoteLedgerUnresolved? fromJson(Map<dynamic, dynamic> json) {
    final String device = _string(json['device']) ?? '';
    if (device.isEmpty) return null;
    return RemoteLedgerUnresolved(
      device: device,
      checked: _string(json['checked']),
    );
  }
}

class RemoteLedgerSearchResult {
  const RemoteLedgerSearchResult({
    required this.remotes,
    required this.unresolved,
  });

  final List<RemoteLedgerEntry> remotes;
  final List<RemoteLedgerUnresolved> unresolved;
}

class RemoteLedgerIndex {
  const RemoteLedgerIndex({required this.remotes, required this.unresolved});

  final List<RemoteLedgerEntry> remotes;
  final List<RemoteLedgerUnresolved> unresolved;

  static const int supportedSchemaVersion = 1;

  /// Parses `index.json`. Throws [FormatException] when it is not an index
  /// this version of the app knows how to read.
  factory RemoteLedgerIndex.fromJson(dynamic json) {
    if (json is! Map) {
      throw const FormatException('The Remote Ledger index is not an object.');
    }
    final dynamic version = json['schemaVersion'];
    if (version != supportedSchemaVersion) {
      throw FormatException(
        'Remote Ledger index schema version $version is not supported.',
      );
    }
    final dynamic remotes = json['remotes'];
    final dynamic unresolved = json['unresolved'];
    return RemoteLedgerIndex(
      remotes: remotes is List
          ? remotes
              .whereType<Map>()
              .map(RemoteLedgerEntry.fromJson)
              .whereType<RemoteLedgerEntry>()
              .toList(growable: false)
          : const <RemoteLedgerEntry>[],
      unresolved: unresolved is List
          ? unresolved
              .whereType<Map>()
              .map(RemoteLedgerUnresolved.fromJson)
              .whereType<RemoteLedgerUnresolved>()
              .toList(growable: false)
          : const <RemoteLedgerUnresolved>[],
    );
  }

  /// Every remote and unresolved device matching [query], by the same rule
  /// as the ledger's own site: [normaliseForSearch] on both sides, and a
  /// query of several words matches when each word is found somewhere.
  ///
  /// The site keeps index order. Here authored remotes come first, because a
  /// search for a maker otherwise opens on dozens of LIRC imports before the
  /// ones checked against independent sources.
  RemoteLedgerSearchResult search(String query) {
    if (normaliseForSearch(query).isEmpty) {
      return const RemoteLedgerSearchResult(
        remotes: <RemoteLedgerEntry>[],
        unresolved: <RemoteLedgerUnresolved>[],
      );
    }
    final List<RemoteLedgerEntry> hits = remotes
        .where((remote) => _matches(query, remote._searchFields))
        .toList();
    final List<RemoteLedgerEntry> authored =
        hits.where((remote) => remote.importedFrom == null).toList();
    final List<RemoteLedgerEntry> imported =
        hits.where((remote) => remote.importedFrom != null).toList();
    return RemoteLedgerSearchResult(
      remotes: <RemoteLedgerEntry>[...authored, ...imported],
      unresolved: unresolved
          .where((device) => _matches(query, <String>[device.device]))
          .toList(growable: false),
    );
  }
}

final RegExp _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Lower case with every space and punctuation mark removed, so `BDP-S360`,
/// `BDP S360` and `BDP.S360` are one string. This is Remote Ledger's
/// `lookup.normalise` and its site's `norm()`, so the app finds what the site
/// finds.
String normaliseForSearch(String text) =>
    text.toLowerCase().replaceAll(_notLetterOrDigit, '');

bool _matches(String query, List<String> values) {
  final String needle = normaliseForSearch(query);
  if (needle.isEmpty) return true;
  final List<String> normalised =
      values.map(normaliseForSearch).toList(growable: false);
  if (normalised.any((value) => value.contains(needle))) return true;
  final List<String> words = query
      .trim()
      .split(RegExp(r'\s+'))
      .map(normaliseForSearch)
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  return words.length > 1 &&
      words.every((word) => normalised.any((value) => value.contains(word)));
}

String? _string(dynamic value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String> _strings(dynamic value) {
  if (value is! List) return const <String>[];
  return value
      .map(_string)
      .whereType<String>()
      .toList(growable: false);
}

/// Fetches the index and keeps the last copy on the device.
///
/// The index is about a megabyte and changes when the ledger does, which is
/// rarely, so a copy younger than [maxAge] is used without asking. An older
/// one is still used when the network fails, since a day-old index finds
/// almost everything a fresh one would.
class RemoteLedgerIndexService {
  RemoteLedgerIndexService({
    http.Client? client,
    Future<Directory> Function()? cacheDirectory,
    DateTime Function()? now,
    this.maxAge = const Duration(hours: 12),
  })  : _client = client ?? http.Client(),
        _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory,
        _now = now ?? DateTime.now;

  static const String _cacheFileName = 'remote_ledger_index.json';

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  final DateTime Function() _now;
  final Duration maxAge;

  RemoteLedgerIndex? _memory;
  DateTime? _memoryFetchedAt;
  Future<RemoteLedgerIndex>? _inFlight;

  /// The index, from memory, the device, or the network in that order.
  /// [forceRefresh] skips straight to the network, and still falls back to
  /// the copy on the device if the network fails.
  Future<RemoteLedgerIndex> load({bool forceRefresh = false}) {
    final RemoteLedgerIndex? memory = _memory;
    final DateTime? fetchedAt = _memoryFetchedAt;
    if (!forceRefresh &&
        memory != null &&
        fetchedAt != null &&
        _now().difference(fetchedAt) < maxAge) {
      return Future<RemoteLedgerIndex>.value(memory);
    }
    return _inFlight ??= _load(forceRefresh: forceRefresh)
        .whenComplete(() => _inFlight = null);
  }

  Future<RemoteLedgerIndex> _load({required bool forceRefresh}) async {
    final File? cache = await _cacheFile();
    if (!forceRefresh && cache != null) {
      final DateTime? modified = await _modified(cache);
      if (modified != null && _now().difference(modified) < maxAge) {
        final RemoteLedgerIndex? cached = await _read(cache);
        if (cached != null) return _remember(cached, modified);
      }
    }

    try {
      final http.Response response = await _client
          .get(Uri.parse(kRemoteLedgerIndexUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException(
          'Remote Ledger index request failed (HTTP ${response.statusCode}).',
        );
      }
      final String body = utf8.decode(response.bodyBytes);
      final RemoteLedgerIndex index =
          RemoteLedgerIndex.fromJson(jsonDecode(body));
      if (cache != null) {
        try {
          await cache.writeAsString(body, flush: true);
        } catch (_) {
          // A cache that cannot be written costs a download next time,
          // nothing more.
        }
      }
      return _remember(index, _now());
    } catch (_) {
      if (cache != null) {
        final RemoteLedgerIndex? stale = await _read(cache);
        if (stale != null) {
          return _remember(stale, await _modified(cache) ?? _now());
        }
      }
      rethrow;
    }
  }

  RemoteLedgerIndex _remember(RemoteLedgerIndex index, DateTime fetchedAt) {
    _memory = index;
    _memoryFetchedAt = fetchedAt;
    return index;
  }

  Future<File?> _cacheFile() async {
    try {
      final Directory dir = await _cacheDirectory();
      return File('${dir.path}/$_cacheFileName');
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> _modified(File file) async {
    try {
      if (!await file.exists()) return null;
      return await file.lastModified();
    } catch (_) {
      return null;
    }
  }

  static Future<RemoteLedgerIndex?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      return RemoteLedgerIndex.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }
}
