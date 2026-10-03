import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:swiftremote/ledger_db/ledger_db.dart';

/// The slice of the Remote Ledger's app API the tests read; see
/// test/fixtures/ledger_api/README.md for what is cut down.
final Directory ledgerFixtures = Directory('test/fixtures/ledger_api');

Uint8List fixtureBytes(String path) =>
    Uint8List.fromList(File('${ledgerFixtures.path}/$path').readAsBytesSync());

dynamic fixtureJson(String path) => jsonDecode(utf8.decode(fixtureBytes(path)));

/// Answers requests for `/app/v1/<path>` from the fixture directory, the way
/// the ledger's Pages site would, and records what was asked.
class FakeLedgerServer {
  FakeLedgerServer({Map<String, Uint8List>? overrides})
      : overrides = overrides ?? <String, Uint8List>{};

  /// Files served instead of the fixture's (or in addition to it).
  final Map<String, Uint8List> overrides;

  /// Paths the server answers with a failure status.
  final Set<String> broken = <String>{};

  /// While true every request fails as a lost connection does.
  bool offline = false;

  /// Answers to give, one per request, before the normal ones: for a server
  /// that serves a wrong file once.
  final Map<String, List<Uint8List>> scripted = <String, List<Uint8List>>{};

  /// Every path requested, in order.
  final List<String> requests = <String>[];

  int count(String path) => requests.where((String p) => p == path).length;

  http.Client client() {
    return MockClient((http.Request request) async {
      final String prefix = '/app/v1/';
      final String path = request.url.path.startsWith(prefix)
          ? request.url.path.substring(prefix.length)
          : request.url.path;
      requests.add(path);
      if (offline) {
        throw const SocketException('Network is unreachable');
      }
      if (broken.contains(path)) {
        return http.Response('boom', 500);
      }
      final List<Uint8List>? script = scripted[path];
      if (script != null && script.isNotEmpty) {
        return http.Response.bytes(script.removeAt(0), 200);
      }
      final Uint8List? override = overrides[path];
      if (override != null) return http.Response.bytes(override, 200);
      final File file = File('${ledgerFixtures.path}/$path');
      if (!file.existsSync()) return http.Response('not found', 404);
      return http.Response.bytes(file.readAsBytesSync(), 200);
    });
  }
}

/// A [LedgerDb] over a [FakeLedgerServer], with its device copy in [dir] and a
/// clock the test controls.
LedgerDb fixtureLedgerDb(
  FakeLedgerServer server,
  Directory dir, {
  DateTime Function()? now,
  int maxCacheBytes = 40 * 1024 * 1024,
  LedgerRunner runner = runInline,
}) {
  return LedgerDb(
    client: server.client(),
    cacheDirectory: () async => dir,
    now: now,
    maxCacheBytes: maxCacheBytes,
    runner: runner,
  );
}

Future<Directory> tempCacheDir() async {
  return Directory.systemTemp.createTemp('ledger_db_test_');
}

/// The file key of a brand of the fixtures.
String brandKey(String name) {
  for (final dynamic row in fixtureJson('brands.json') as List<dynamic>) {
    if ((row as List<dynamic>)[0] == name) return row[1] as String;
  }
  throw ArgumentError('No brand $name in the fixtures');
}

/// The manifest of the fixtures with its `dataVersion` changed.
Uint8List manifestWithDataVersion(String dataVersion) {
  final Map<String, dynamic> m =
      Map<String, dynamic>.from(fixtureJson('manifest.json') as Map);
  m['dataVersion'] = dataVersion;
  return Uint8List.fromList(utf8.encode(jsonEncode(m)));
}
