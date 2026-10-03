import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ledger_db/ledger_cache.dart';
import 'package:swiftremote/ledger_db/ledger_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';

import 'support/ledger_fixtures.dart';

void main() {
  late Directory dir;
  late FakeLedgerServer server;
  late DateTime now;

  setUp(() async {
    dir = await tempCacheDir();
    server = FakeLedgerServer();
    now = DateTime.utc(2026, 10, 3, 12);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  LedgerDb open({
    FakeLedgerServer? over,
    int maxCacheBytes = 40 * 1024 * 1024,
    LedgerRunner runner = runInline,
  }) =>
      fixtureLedgerDb(
        over ?? server,
        dir,
        now: () => now,
        maxCacheBytes: maxCacheBytes,
        runner: runner,
      );

  String keyOf(String brand) => brandKey(brand);

  group('first use', () {
    test('reads the manifest, then each file once, and nothing is asked twice',
        () async {
      final LedgerDb db = open();

      final LedgerManifest m = await db.manifest();
      expect(m.dataVersion, isNotEmpty);
      expect(db.dataVersion, m.dataVersion);
      expect(await db.brands(), hasLength(4902));
      await db.brands();
      await db.manifest();

      expect(server.requests, <String>['manifest.json', 'brands.json']);
    });

    test('a brand takes two requests, its models and its keys, and no more',
        () async {
      final LedgerDb db = open();
      final String key = keyOf('B2B.TEST');

      final LedgerBrandData data = await db.brand(key);
      expect(data.models.brand, 'B2B.TEST');
      expect(data.keys.rowCount, greaterThan(50));
      await db.brand(key);
      await db.brandModels(key);

      expect(server.requests, <String>[
        'manifest.json',
        'b/$key.m.json',
        'b/$key.k.json',
      ]);
    });

    test('concurrent loads of one file share one request', () async {
      final LedgerDb db = open();
      final String key = keyOf('B2B.TEST');

      await Future.wait(<Future<Object?>>[
        db.brand(key),
        db.brand(key),
        db.brandModels(key),
        db.brands(),
        db.brands(),
      ]);

      expect(server.count('b/$key.m.json'), 1);
      expect(server.count('b/$key.k.json'), 1);
      expect(server.count('brands.json'), 1);
      expect(server.count('manifest.json'), 1);
    });

    test('a signal shard and the power list load on their own', () async {
      final LedgerDb db = open();

      final LedgerSignalShard shard = await db.signalShard('Sharp');
      expect(shard.signals, isNotEmpty);
      await db.signalShard('Sharp');
      expect((await db.power()).first.label, 'POWER');

      expect(server.count('s/Sharp.json'), 1);
      expect(server.count('power.json'), 1);
    });

    test('keeps a file name from walking out of the database', () {
      final LedgerDb db = open();
      expect(() => db.brandModels('../x'), throwsArgumentError);
      expect(() => db.signalShard('a/b'), throwsArgumentError);
    });
  });

  group('the manifest', () {
    test('is looked at again only after half a day', () async {
      final LedgerDb db = open();
      await db.manifest();

      now = now.add(const Duration(hours: 11, minutes: 59));
      await db.manifest();
      expect(server.count('manifest.json'), 1);

      now = now.add(const Duration(minutes: 2));
      await db.manifest();
      expect(server.count('manifest.json'), 2);
    });

    test('is not looked at at all when the caller says so', () async {
      final LedgerDb db = open();
      await db.manifest();
      now = now.add(const Duration(days: 3));

      await db.manifest(refresh: false);

      expect(server.count('manifest.json'), 1);
    });

    test('is read from the device by a new process, if it is young', () async {
      final LedgerDb first = open();
      await first.manifest();
      await first.flush();

      now = now.add(const Duration(hours: 1));
      final FakeLedgerServer second = FakeLedgerServer();
      final LedgerDb db = open(over: second);
      expect((await db.manifest()).dataVersion, first.dataVersion);

      expect(second.requests, isEmpty);
    });

    test(
        'a failed look-up keeps the copy on the device and is not repeated at once',
        () async {
      final LedgerDb first = open();
      await first.manifest();
      await first.flush();

      now = now.add(const Duration(hours: 13));
      final FakeLedgerServer offline = FakeLedgerServer()..offline = true;
      final LedgerDb db = open(over: offline);

      expect((await db.manifest()).dataVersion, first.dataVersion);
      expect(offline.count('manifest.json'), 1);

      // Not again for ten minutes, however often it is asked.
      now = now.add(const Duration(minutes: 5));
      await db.manifest();
      await db.manifest();
      expect(offline.count('manifest.json'), 1);

      now = now.add(const Duration(minutes: 6));
      await db.manifest();
      expect(offline.count('manifest.json'), 2);
    });

    test('a manifest from the future is refused: nothing to fall back on',
        () async {
      final Map<String, dynamic> v2 =
          Map<String, dynamic>.from(fixtureJson('manifest.json') as Map)
            ..['schemaVersion'] = 2;
      server.overrides['manifest.json'] =
          Uint8List.fromList(utf8.encode(jsonEncode(v2)));
      final LedgerDb db = open();

      await expectLater(
        db.manifest(),
        throwsA(isA<LedgerDbUnavailable>()
            .having((LedgerDbUnavailable e) => e.reason, 'reason',
                LedgerDbFailure.unsupportedVersion)
            .having(
                (LedgerDbUnavailable e) => e.retryable, 'retryable', isFalse)),
      );
      expect(File('${dir.path}/manifest.json').existsSync(), isFalse);
    });

    test('a manifest from the future does not displace the one that works',
        () async {
      final LedgerDb first = open();
      final String dataVersion = (await first.manifest()).dataVersion;
      await first.flush();

      now = now.add(const Duration(hours: 13));
      final Map<String, dynamic> v2 =
          Map<String, dynamic>.from(fixtureJson('manifest.json') as Map)
            ..['schemaVersion'] = 2;
      final FakeLedgerServer later =
          FakeLedgerServer(overrides: <String, Uint8List>{
        'manifest.json': Uint8List.fromList(utf8.encode(jsonEncode(v2))),
      });
      final LedgerDb db = open(over: later);

      expect((await db.manifest()).dataVersion, dataVersion);
      final File cached = File('${dir.path}/manifest.json');
      expect((LedgerManifest.parse(cached.readAsBytesSync())).schemaVersion, 1);
    });

    test('a broken manifest is not a manifest', () async {
      server.overrides['manifest.json'] =
          Uint8List.fromList(utf8.encode('{broken'));
      final LedgerDb db = open();

      await expectLater(
        db.manifest(),
        throwsA(isA<LedgerDbUnavailable>().having(
            (LedgerDbUnavailable e) => e.reason,
            'reason',
            LedgerDbFailure.corrupt)),
      );
    });
  });

  group('offline', () {
    test('first use with no network and nothing saved says so', () async {
      server.offline = true;
      final LedgerDb db = open();

      await expectLater(
        db.manifest(),
        throwsA(isA<LedgerDbUnavailable>()
            .having((LedgerDbUnavailable e) => e.reason, 'reason',
                LedgerDbFailure.offline)
            .having(
                (LedgerDbUnavailable e) => e.retryable, 'retryable', isTrue)),
      );
      await expectLater(db.brands(), throwsA(isA<LedgerDbUnavailable>()));
    });

    test('a server error is not an empty answer', () async {
      server.broken.add('manifest.json');
      final LedgerDb db = open();

      await expectLater(
        db.manifest(),
        throwsA(isA<LedgerDbUnavailable>().having(
            (LedgerDbUnavailable e) => e.reason,
            'reason',
            LedgerDbFailure.server)),
      );
    });

    test('a brand never opened cannot be had offline, one opened before can',
        () async {
      final String seen = keyOf('B2B.TEST');
      final String unseen = keyOf('UNIDEN');
      final LedgerDb online = open();
      await online.brand(seen);
      await online.brands();
      await online.flush();

      final FakeLedgerServer offline = FakeLedgerServer()..offline = true;
      final LedgerDb db = open(over: offline);

      expect((await db.brand(seen)).keys.rowCount, greaterThan(0));
      expect(await db.brands(), hasLength(4902));
      await expectLater(db.brand(unseen), throwsA(isA<LedgerDbUnavailable>()));
      expect(offline.requests.where((String p) => p.contains(seen)), isEmpty);
    });

    test('an uncached signal shard is unavailable offline', () async {
      final LedgerDb online = open();
      await online.manifest();
      await online.flush();

      final LedgerDb db = open(over: FakeLedgerServer()..offline = true);

      await expectLater(
          db.signalShard('Sharp'), throwsA(isA<LedgerDbUnavailable>()));
    });
  });

  group('when the data changes', () {
    // A new dataVersion with the same files: what the ledger publishes when
    // something elsewhere changed.
    Future<LedgerDb> afterNewDataVersion(
      String key, {
      Map<String, Uint8List> overrides = const <String, Uint8List>{},
    }) async {
      final LedgerDb first = open();
      await first.brand(key);
      await first.brands();
      await first.signalShard('Sharp');
      await first.flush();

      now = now.add(const Duration(hours: 13));
      final FakeLedgerServer second =
          FakeLedgerServer(overrides: <String, Uint8List>{
        'manifest.json': manifestWithDataVersion('feedfacefeed'),
        ...overrides,
      });
      server = second;
      return open(over: second);
    }

    test(
        'small files are fetched again, a brand\'s keys only if their hash moved',
        () async {
      final String key = keyOf('B2B.TEST');
      final LedgerDb db = await afterNewDataVersion(key);

      expect((await db.manifest()).dataVersion, 'feedfacefeed');
      await db.brands();
      await db.brand(key);
      await db.signalShard('Sharp');

      expect(server.count('manifest.json'), 1);
      expect(server.count('brands.json'), 1);
      expect(server.count('b/$key.m.json'), 1);
      expect(server.count('b/$key.k.json'), 0,
          reason: 'the keys did not change: their hash is the same');
      expect(server.count('s/Sharp.json'), 1);
    });

    test('a brand whose hash moved gets its keys fetched again', () async {
      final String key = keyOf('B2B.TEST');
      // New keys for the brand, and a models file that names their hash.
      final Map<String, dynamic> keys =
          Map<String, dynamic>.from(fixtureJson('b/$key.k.json') as Map);
      final List<dynamic> blocks = List<dynamic>.from(keys['r'] as List);
      final List<dynamic> first = List<dynamic>.from(blocks.first as List);
      final List<dynamic> rows = List<dynamic>.from(first[1] as List)
        ..add(<Object?>['NEW KEY', 3, 'ABCD']);
      first[1] = rows;
      blocks[0] = first;
      keys['r'] = blocks;
      final Uint8List keyBytes =
          Uint8List.fromList(utf8.encode(jsonEncode(keys)));
      final Map<String, dynamic> models =
          Map<String, dynamic>.from(fixtureJson('b/$key.m.json') as Map)
            ..['hash'] = sha256.convert(keyBytes).toString().substring(0, 6);
      final LedgerDb db =
          await afterNewDataVersion(key, overrides: <String, Uint8List>{
        'b/$key.k.json': keyBytes,
        'b/$key.m.json': Uint8List.fromList(utf8.encode(jsonEncode(models))),
      });
      await db.manifest();

      final LedgerBrandData data = await db.brand(key);

      expect(data.keys.labels, contains('NEW KEY'));
      expect(server.count('b/$key.k.json'), 1);
    });

    test('whatever is on the device stands in when the new files cannot be had',
        () async {
      final String key = keyOf('B2B.TEST');
      final LedgerDb db = await afterNewDataVersion(key);
      await db.manifest();
      server.offline = true;

      expect(await db.brands(), hasLength(4902));
      expect((await db.brand(key)).keys.rowCount, greaterThan(0));
      expect((await db.signalShard('Sharp')).signals, isNotEmpty);
    });

    test('what a new data version supersedes is dropped from memory', () async {
      final String key = keyOf('B2B.TEST');
      final LedgerDb db = open();
      await db.brand(key);
      await db.brands();
      final int brandRequests = server.count('brands.json');

      now = now.add(const Duration(hours: 13));
      server.overrides['manifest.json'] =
          manifestWithDataVersion('0123456789ab');
      await db.manifest();
      await db.brands();

      expect(server.count('brands.json'), brandRequests + 1);
    });
  });

  group('a brand\'s key file and its hash', () {
    test('a file that disagrees is rejected and fetched once more', () async {
      final String key = keyOf('B2B.TEST');
      server.scripted['b/$key.k.json'] = <Uint8List>[
        Uint8List.fromList(utf8.encode('{"brand":"B2B.TEST","r":[]}')),
      ];
      final LedgerDb db = open();

      final LedgerBrandData data = await db.brand(key);

      expect(data.keys.rowCount, greaterThan(50),
          reason: 'the second answer was used');
      expect(server.count('b/$key.k.json'), 2);
      expect(
          sha256
              .convert(File('${dir.path}/b/$key.k.json').readAsBytesSync())
              .toString(),
          startsWith(data.models.hash));
    });

    test('a file that still disagrees is not used and not kept', () async {
      final String key = keyOf('B2B.TEST');
      final Uint8List wrong =
          Uint8List.fromList(utf8.encode('{"brand":"B2B.TEST","r":[]}'));
      server.scripted['b/$key.k.json'] = <Uint8List>[wrong, wrong, wrong];
      final LedgerDb db = open();

      await expectLater(
        db.brand(key),
        throwsA(isA<LedgerDbUnavailable>().having(
            (LedgerDbUnavailable e) => e.reason,
            'reason',
            LedgerDbFailure.server)),
      );

      expect(server.count('b/$key.k.json'), 2, reason: 'once, and once more');
      expect(File('${dir.path}/b/$key.k.json').existsSync(), isFalse);
      // And the brand loads when the server comes right.
      server.scripted.clear();
      expect((await db.brand(key)).keys.rowCount, greaterThan(50));
    });

    test('a copy on the device that no longer fits is replaced, or stands in',
        () async {
      final String key = keyOf('B2B.TEST');
      final LedgerDb first = open();
      await first.brand(key);
      await first.flush();

      // The models file of a newer brand names a different hash.
      now = now.add(const Duration(hours: 13));
      final Map<String, dynamic> models =
          Map<String, dynamic>.from(fixtureJson('b/$key.m.json') as Map)
            ..['hash'] = 'ffffff';
      final FakeLedgerServer changed =
          FakeLedgerServer(overrides: <String, Uint8List>{
        'manifest.json': manifestWithDataVersion('aaaaaaaaaaaa'),
        'b/$key.m.json': Uint8List.fromList(utf8.encode(jsonEncode(models))),
      });
      final LedgerDb db = open(over: changed);
      await db.manifest();

      // The server's key file cannot match ffffff, so the copy on the device
      // (a brand's keys as of an earlier day) is used.
      final LedgerBrandData data = await db.brand(key);

      expect(data.keys.rowCount, greaterThan(50));
      expect(changed.count('b/$key.k.json'), 2);
    });

    test('a damaged copy on the device is deleted and fetched again', () async {
      final String key = keyOf('B2B.TEST');
      final LedgerDb first = open();
      await first.brand(key);
      await first.flush();
      File('${dir.path}/b/$key.k.json').writeAsStringSync('not json at all');

      final LedgerDb db = open(over: FakeLedgerServer());
      final LedgerBrandData data = await db.brand(key);

      expect(data.keys.rowCount, greaterThan(50));
    });
  });

  group('the copy on the device', () {
    test('is in the support directory layout and has no staging files left',
        () async {
      final LedgerDb db = open();
      await db.brand(keyOf('B2B.TEST'));
      await db.brands();
      await db.flush();

      final List<String> files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((File f) => f.path.substring(dir.path.length + 1))
          .toList()
        ..sort();
      expect(files, contains('manifest.json'));
      expect(files, contains('brands.json'));
      expect(files, contains('meta.json'));
      expect(files.where((String f) => f.startsWith('b/')), hasLength(2));
      expect(files.where((String f) => f.endsWith('.tmp')), isEmpty);
    });

    test('a staging file an interrupted write left is removed when it opens',
        () async {
      Directory('${dir.path}/b').createSync(recursive: true);
      File('${dir.path}/b/abc.k.json.tmp').writeAsStringSync('half a fil');
      File('${dir.path}/manifest.json.tmp').writeAsStringSync('{');

      final LedgerDb db = open();
      await db.manifest();

      expect(File('${dir.path}/b/abc.k.json.tmp').existsSync(), isFalse);
      expect(File('${dir.path}/manifest.json.tmp').existsSync(), isFalse);
    });

    test('works when there is nowhere to keep files', () async {
      final LedgerDb db = LedgerDb(
        client: server.client(),
        cacheDirectory: () async =>
            throw const FileSystemException('read-only'),
        now: () => now,
        runner: runInline,
      );

      expect((await db.brand(keyOf('B2B.TEST'))).keys.rowCount, greaterThan(0));
    });

    test(
        'is trimmed from the least recently used brand when it outgrows its cap',
        () async {
      final String a = keyOf('B2B.TEST');
      final String b = keyOf('UNIDEN');
      final String c = keyOf('BRENNAN');
      int sizeOf(String key) =>
          File('test/fixtures/ledger_api/b/$key.k.json').lengthSync() +
          File('test/fixtures/ledger_api/b/$key.m.json').lengthSync();
      // Room for the last two, not for all three.
      final LedgerDb db = open(maxCacheBytes: sizeOf(b) + sizeOf(c) + 100);

      await db.brand(a);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await db.brand(b);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await db.brand(c);

      expect(File('${dir.path}/b/$c.k.json').existsSync(), isTrue,
          reason: 'the newest stays');
      expect(File('${dir.path}/b/$a.k.json').existsSync(), isFalse,
          reason: 'the oldest goes first, with its models file');
      expect(File('${dir.path}/b/$a.m.json').existsSync(), isFalse);
      expect(File('${dir.path}/manifest.json').existsSync(), isTrue,
          reason: 'the manifest is never evicted');
    });

    test('LedgerCache refuses a path outside its directory', () async {
      final LedgerCache cache = LedgerCache(dir);
      await expectLater(cache.read('../x'), throwsArgumentError);
      await expectLater(cache.write('/abs', Uint8List(1)), throwsArgumentError);
      await expectLater(
          cache.write('a/../b', Uint8List(1)), throwsArgumentError);
      expect(await cache.write('b/ok.json', Uint8List.fromList(<int>[1, 2])),
          isTrue);
      expect(await cache.read('b/ok.json'), <int>[1, 2]);
      expect(await cache.read('b/missing.json'), isNull);
    });
  });

  group('parsing off the main isolate', () {
    test(
        'a brand file big enough to be sent to another isolate parses the same',
        () async {
      // About 400 KB: past the point where the hop pays.
      final List<List<Object?>> rows = <List<Object?>>[
        for (int i = 0; i < 9000; i++)
          <Object?>['KEY $i', i % 23, i.toRadixString(16).toUpperCase()],
      ];
      final Uint8List keyBytes =
          Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
        'brand': 'BIGGY',
        'r': <Object?>[
          <Object?>[7, rows.sublist(0, 4500)],
          <Object?>[8, rows.sublist(4500)],
        ],
      })));
      expect(keyBytes.length, greaterThan(kLedgerOffloadBytes));
      final String hash = sha256.convert(keyBytes).toString().substring(0, 6);
      final Uint8List modelBytes =
          Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
        'brand': 'BIGGY',
        'hash': hash,
        'ids': <Object?>[
          <Object?>[7, 1, 4500],
          <Object?>[8, 1, 4500],
        ],
        'models': <Object?>[
          <Object?>[
            'M',
            <Object?>[0, 1]
          ],
        ],
      })));
      server.overrides['b/0123456789.k.json'] = keyBytes;
      server.overrides['b/0123456789.m.json'] = modelBytes;
      final LedgerDb db = open(runner: runOffloaded);

      final LedgerBrandData data = await db.brand('0123456789');

      expect(data.keys.rowCount, 9000);
      expect(data.keys.labels[8999], 'KEY 8999');
      expect(data.keys.protocols[22], 22);
      expect(data.keys.blockOf(8), 1);
      expect(data.keys.hexes[255], 'FF');
    });

    test('hands only the parse, not the database, to the runner', () async {
      final List<int> weights = <int>[];
      Future<R> record<R>(R Function() computation, {int weight = 0}) {
        weights.add(weight);
        return runInline<R>(computation, weight: weight);
      }

      final LedgerDb db = open(runner: record);
      await db.brand(keyOf('B2B.TEST'));

      expect(weights, hasLength(2));
      expect(weights.every((int w) => w > 0), isTrue);
    });
  });
}
