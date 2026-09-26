import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:swiftremote/github_store/remote_ledger_index.dart';

// Entries shaped exactly as Remote Ledger's site/index.json writes them.
final Map<String, Object> indexJson = <String, Object>{
  'schemaVersion': 1,
  'remotes': <Object>[
    <String, Object>{
      'aliases': <String>[],
      'artifact': 'build/pronto/lirc/sony/RMT-B118P.json',
      'confidence': 'plausible',
      'controls': <String>[],
      'file': 'remotes/lirc/sony/RMT-B118P.json',
      'importedFrom': 'remotes/lirc/',
      'keyCount': 30,
      'manufacturer': 'Sony',
      'model': 'RMT-B118P',
      'unresolvedAlternates': 0,
    },
    <String, Object>{
      'aliases': <String>[],
      'artifact': 'build/pronto/sony/RMT-B118P.json',
      'confidence': 'plausible',
      'controls': <String>['BDP-S185'],
      'file': 'remotes/sony/RMT-B118P.json',
      'keyCount': 38,
      'manufacturer': 'Sony',
      'model': 'RMT-B118P',
      'protocol': 'Sony20',
      'unresolvedAlternates': 0,
    },
    <String, Object>{
      'aliases': <String>['RC15A'],
      'artifact': 'build/pronto/topping/RC-15A.json',
      'confidence': 'verified',
      'controls': <String>['DX3 Pro', 'D50s'],
      'file': 'remotes/topping/RC-15A.json',
      'keyCount': 12,
      'manufacturer': 'Topping',
      'model': 'RC-15A',
      'protocol': 'NEC1',
      'unresolvedAlternates': 0,
    },
  ],
  'unresolved': <Object>[
    <String, Object>{
      'checked': '2026-09-24',
      'device': 'Sony BDP-BX510',
      'note': 'A contradiction rather than an absence.',
    },
  ],
};

RemoteLedgerIndex index() => RemoteLedgerIndex.fromJson(indexJson);

List<String> artifacts(RemoteLedgerSearchResult result) =>
    result.remotes.map((remote) => remote.artifact).toList();

void main() {
  group('search', () {
    test('finds a remote by a device it controls', () {
      expect(
        artifacts(index().search('BDP-S185')),
        <String>['build/pronto/sony/RMT-B118P.json'],
      );
    });

    test('ignores spaces and punctuation on both sides, as the site does',
        () {
      for (final query in <String>['bdp s185', 'BDP.S185', 'bdps185']) {
        expect(
          artifacts(index().search(query)),
          <String>['build/pronto/sony/RMT-B118P.json'],
          reason: query,
        );
      }
    });

    test('matches several words when each is found somewhere', () {
      expect(
        artifacts(index().search('topping dx3')),
        <String>['build/pronto/topping/RC-15A.json'],
      );
      expect(index().search('topping bdp').remotes, isEmpty);
    });

    test('lists authored remotes before imported ones', () {
      expect(
        artifacts(index().search('RMT-B118P')),
        <String>[
          'build/pronto/sony/RMT-B118P.json',
          'build/pronto/lirc/sony/RMT-B118P.json',
        ],
      );
    });

    test('reports a device recorded as checked with nothing found', () {
      final result = index().search('bx510');
      expect(result.remotes, isEmpty);
      expect(result.unresolved.single.device, 'Sony BDP-BX510');
      expect(result.unresolved.single.checked, '2026-09-24');
    });

    test('an empty query finds nothing rather than everything', () {
      expect(index().search('  - ').remotes, isEmpty);
    });
  });

  test('an index with an unknown schema version is refused', () {
    expect(
      () => RemoteLedgerIndex.fromJson(<String, Object>{
        'schemaVersion': 2,
        'remotes': <Object>[],
      }),
      throwsFormatException,
    );
  });

  test('an entry keeps what the store needs to open and describe it', () {
    final topping = index().remotes.last;
    expect(topping.title, 'Topping RC-15A');
    expect(topping.fileName, 'RC-15A.json');
    expect(topping.controls, <String>['DX3 Pro', 'D50s']);
    expect(topping.protocol, 'NEC1');
    expect(topping.importedFrom, isNull);
  });

  group('service', () {
    late Directory cacheDir;
    late int requests;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('ledger_index_test');
      requests = 0;
    });

    tearDown(() async {
      await cacheDir.delete(recursive: true);
    });

    http.Client serving(String body, {int status = 200}) {
      return MockClient((request) async {
        requests++;
        expect(request.url.toString(), kRemoteLedgerIndexUrl);
        return http.Response.bytes(utf8.encode(body), status);
      });
    }

    final http.Client offline = MockClient((request) async {
      throw const SocketException('offline');
    });

    RemoteLedgerIndexService service(
      http.Client client, {
      Duration maxAge = const Duration(hours: 12),
    }) {
      return RemoteLedgerIndexService(
        client: client,
        cacheDirectory: () async => cacheDir,
        maxAge: maxAge,
      );
    }

    test('downloads the index once and keeps it for the next launch',
        () async {
      final first = service(serving(jsonEncode(indexJson)));
      expect((await first.load()).remotes, hasLength(3));
      expect((await first.load()).remotes, hasLength(3));
      expect(requests, 1);

      final nextLaunch = service(offline);
      expect((await nextLaunch.load()).remotes, hasLength(3));
    });

    test('falls back to an old copy when the network fails', () async {
      await service(serving(jsonEncode(indexJson))).load();

      final stale = service(offline, maxAge: Duration.zero);
      expect((await stale.load()).remotes, hasLength(3));
    });

    test('a forced refresh asks the network even with a fresh copy',
        () async {
      await service(serving(jsonEncode(indexJson))).load();
      final refreshed = <String, Object>{
        ...indexJson,
        'remotes': <Object>[(indexJson['remotes'] as List<Object>).first],
      };

      final again = service(serving(jsonEncode(refreshed)));
      expect((await again.load(forceRefresh: true)).remotes, hasLength(1));
      expect(requests, 2);
    });

    test('with no copy and no network, the failure reaches the caller',
        () async {
      await expectLater(service(offline).load(), throwsA(isA<Exception>()));
    });

    test('a failed response is not cached', () async {
      await expectLater(
        service(serving('nope', status: 503)).load(),
        throwsA(isA<HttpException>()),
      );
      await expectLater(service(offline).load(), throwsA(isA<Exception>()));
    });
  });
}
