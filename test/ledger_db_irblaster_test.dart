import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/ledger_db/ledger_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';

import 'support/ledger_fixtures.dart';

void main() {
  late Directory dir;
  late FakeLedgerServer server;
  late int selectionsBuilt;

  setUp(() async {
    dir = await tempCacheDir();
    server = FakeLedgerServer();
    selectionsBuilt = 0;
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// A database over the fixtures that counts how many selections it builds.
  IrBlasterDb open({FakeLedgerServer? over, DateTime Function()? now}) {
    Future<R> counting<R>(R Function() computation, {int weight = 0}) {
      if (R == Int32List) selectionsBuilt++;
      return runInline<R>(computation, weight: weight);
    }

    return IrBlasterDb.forTesting(
      fixtureLedgerDb(over ?? server, dir, now: now, runner: counting),
      runner: counting,
    );
  }

  Future<List<IrDbKeyCandidate>> allKeys(
    IrBlasterDb db,
    String brand, {
    String? model,
    String? protocol,
    bool quick = true,
  }) =>
      db.fetchCandidateKeys(
        brand: brand,
        model: model,
        selectedProtocolId: protocol,
        quickWinsFirst: quick,
        limit: 1 << 30,
      );

  group('nothing is read until it is asked for', () {
    test('creating the database makes no request', () {
      open();
      expect(server.requests, isEmpty);
    });

    test('initialising reads the manifest and the brands, once', () async {
      final IrBlasterDb db = open();

      await db.ensureInitialized();
      await db.ensureInitialized();
      await db.listBrands();

      expect(server.requests, <String>['manifest.json', 'brands.json']);
      expect(db.dataVersion, isNotNull);
    });

    test('a query on a database not yet initialised initialises it', () async {
      final IrBlasterDb db = open();

      expect(await db.listBrands(limit: 3), hasLength(3));

      expect(server.requests, <String>['manifest.json', 'brands.json']);
    });

    test(
        'listing brands, protocols of a brand and brand names needs no brand file',
        () async {
      final IrBlasterDb db = open();

      await db.listBrands(search: 'a');
      await db.listProtocolsForBrand('BRENNAN');

      expect(server.requests.where((String p) => p.startsWith('b/')), isEmpty);
    });

    test('models and protocols of a model need the small file, not the keys',
        () async {
      final IrBlasterDb db = open();

      await db.listModelsDistinct(brand: 'BRENNAN');
      await db.listProtocolsFor(
        brand: 'BRENNAN',
        model: (await db.listModelsDistinct(brand: 'BRENNAN')).first,
      );

      expect(
          server.requests.where((String p) => p.endsWith('.k.json')), isEmpty);
      expect(server.requests.where((String p) => p.endsWith('.m.json')),
          hasLength(1));
    });

    test('a failed initialisation can be tried again', () async {
      server.offline = true;
      final IrBlasterDb db = open();

      await expectLater(
          db.ensureInitialized(), throwsA(isA<LedgerDbUnavailable>()));
      await expectLater(db.listBrands(), throwsA(isA<LedgerDbUnavailable>()));

      server.offline = false;
      await db.ensureInitialized();
      expect(await db.listBrands(limit: 2), hasLength(2));
    });
  });

  group('keys are listed once each', () {
    test('a whole brand lists each key once, not once per model', () async {
      final IrBlasterDb db = open();
      final String key = brandKey('DAEWOO');
      final LedgerBrandKeys keys =
          LedgerBrandKeys.parse(fixtureBytes('b/$key.k.json'));

      final List<IrDbKeyCandidate> rows = await allKeys(db, 'DAEWOO');

      expect(rows, hasLength(keys.rowCount));
      final Set<String> seen = rows
          .map((IrDbKeyCandidate r) =>
              '${r.id}|${r.label}|${r.hexcode}|${r.protocol}')
          .toSet();
      expect(seen, hasLength(rows.length));
      // The old join would have returned a row for every model of every id.
      final LedgerBrandModels models =
          LedgerBrandModels.parse(fixtureBytes('b/$key.m.json'));
      int perModel = 0;
      for (final LedgerModel m in models.models) {
        for (final int i in m.idIndexes) {
          perModel += models.idKeyCounts[i];
        }
      }
      expect(perModel, greaterThan(rows.length));
    });

    test(
        'a row names its model: the asked one, else the first that uses the id',
        () async {
      final IrBlasterDb db = open();
      final List<String> models =
          await db.listModelsDistinct(brand: 'DAEWOO', limit: 1 << 30);

      final List<IrDbKeyCandidate> one =
          await allKeys(db, 'DAEWOO', model: models[10]);
      expect(one, isNotEmpty);
      expect(one.every((IrDbKeyCandidate r) => r.model == models[10]), isTrue);

      final List<IrDbKeyCandidate> all = await allKeys(db, 'DAEWOO');
      expect(
          all.every((IrDbKeyCandidate r) => models.contains(r.model)), isTrue);
      expect(all.every((IrDbKeyCandidate r) => r.brand == 'DAEWOO'), isTrue);
      expect(all.every((IrDbKeyCandidate r) => r.remoteId == r.id), isTrue);
    });
  });

  group('the Signal Tester\'s loop', () {
    test('asks for one row at a time and pays for the selection once',
        () async {
      final IrBlasterDb db = open();
      final List<IrDbKeyCandidate> whole =
          await allKeys(db, 'DAEWOO', protocol: 'nec');
      expect(whole.length, greaterThan(50));
      final int built = selectionsBuilt;
      final int requests = server.requests.length;

      for (int offset = 0; offset < 50; offset++) {
        final List<IrDbKeyCandidate> one = await db.fetchCandidateKeys(
          brand: 'DAEWOO',
          selectedProtocolId: 'nec',
          quickWinsFirst: true,
          limit: 1,
          offset: offset,
        );
        expect(one, hasLength(1));
        expect(one.single.hexcode, whole[offset].hexcode);
        expect(one.single.label, whole[offset].label);
      }

      expect(selectionsBuilt, built, reason: 'no filtering or sorting again');
      expect(server.requests.length, requests, reason: 'no network');
    });

    test('a different question builds its own selection', () async {
      final IrBlasterDb db = open();
      await allKeys(db, 'BRENNAN');
      final int built = selectionsBuilt;

      await allKeys(db, 'BRENNAN', quick: false);
      await allKeys(db, 'BRENNAN', protocol: 'sony12');

      expect(selectionsBuilt, built + 2);
    });

    test('a count needs no ordering and reuses its own answer', () async {
      final IrBlasterDb db = open();
      final int a = await db.countCandidateKeys(brand: 'DAEWOO');
      final int built = selectionsBuilt;
      final int b = await db.countCandidateKeys(brand: 'DAEWOO');

      expect(a, b);
      expect(selectionsBuilt, built);
      expect(a, (await allKeys(db, 'DAEWOO')).length);
    });

    test('prepareCandidates loads everything: the run then needs no network',
        () async {
      final IrBlasterDb db = open();

      final int n =
          await db.prepareCandidates(brand: 'BRENNAN', quickWinsFirst: true);
      expect(n, greaterThan(0));
      server.offline = true;
      final int requests = server.requests.length;

      for (int offset = 0; offset < n; offset++) {
        final List<IrDbKeyCandidate> one = await db.fetchCandidateKeys(
          brand: 'BRENNAN',
          quickWinsFirst: true,
          limit: 1,
          offset: offset,
        );
        expect(one, hasLength(1));
        expect(one.single.signal, isNotNull,
            reason: 'row $offset carries its signal');
      }

      expect(server.requests.length, requests,
          reason: 'nothing was asked of the server after the run was prepared');
    });

    test(
        'prepareCandidates fails, with a reason, when a needed signal is missing',
        () async {
      server.offline = false;
      server.broken.add('s/SONY15.json');
      final IrBlasterDb db = open();

      await expectLater(
        db.prepareCandidates(brand: 'BRENNAN', quickWinsFirst: true),
        throwsA(isA<LedgerDbUnavailable>()),
      );
      // The same brand without the protocol whose signal is missing is fine.
      expect(
        await db.prepareCandidates(
          brand: 'BRENNAN',
          selectedProtocolId: 'sony12',
          quickWinsFirst: true,
        ),
        greaterThan(0),
      );
    });
  });

  group('protocols played from the ledger\'s signal', () {
    test('a row of the ten carries its compiled signal and says it needs it',
        () async {
      final IrBlasterDb db = open();
      for (final (String brand, String protocol) in <(String, String)>[
        ('BRENNAN', 'SONY12'),
        ('BRENNAN', 'SONY15'),
        ('BRENNAN', 'SONY20'),
        ('AMCREST', 'Pioneer'),
        ('VOLVO', 'JVC'),
        ('UNIDEN', 'Denon'),
        ('STRIM(AMINO)', 'Sharp'),
        ('B2B.TEST', 'Thomson7'),
        ('SATEC', 'Proton'),
        ('JIN LIPU', 'RCC2026'),
      ]) {
        final List<IrDbKeyCandidate> rows =
            await allKeys(db, brand, protocol: protocol);
        expect(rows, isNotEmpty, reason: '$brand $protocol');
        for (final IrDbKeyCandidate r in rows) {
          expect(r.protocol, protocol);
          expect(r.requiresSignal, isTrue,
              reason: '$brand $protocol ${r.label}');
          expect(r.signal, isNotNull, reason: '$brand $protocol ${r.label}');
          expect(r.signal!.hexcode, r.hexcode);
          expect(r.signal!.protocol, protocol);
          expect(r.signal!.playback(), isNotNull);
        }
      }
    });

    test('a row of any other protocol carries no signal and loads none',
        () async {
      final IrBlasterDb db = open();

      for (final (String brand, String protocol) in <(String, String)>[
        ('AS', 'NEC'),
        ('TRICE', 'NEC2'),
        ('FRITZU', 'RC5'),
        ('T+A', 'RCC0082'),
        ('B2B.TEST', 'RCA_38'),
      ]) {
        final List<IrDbKeyCandidate> rows =
            await allKeys(db, brand, protocol: protocol);
        expect(rows, isNotEmpty, reason: brand);
        expect(
            rows.every(
                (IrDbKeyCandidate r) => !r.requiresSignal && r.signal == null),
            isTrue,
            reason: brand);
      }
      expect(server.requests.where((String p) => p.startsWith('s/')), isEmpty);
    });

    test('each protocol\'s file is loaded once, however many keys use it',
        () async {
      final IrBlasterDb db = open();

      await allKeys(db, 'BRENNAN');
      await allKeys(db, 'BRENNAN', quick: false);
      await allKeys(db, 'STRIM(AMINO)');

      expect(server.count('s/SONY12.json'), 1);
      expect(server.count('s/SONY15.json'), 1);
      expect(server.count('s/Sharp.json'), 1);
    });

    test('a listing that needs a signal that cannot be had fails as a whole',
        () async {
      server.offline = false;
      server.broken.add('s/Denon.json');
      final IrBlasterDb db = open();

      await expectLater(
          allKeys(db, 'UNIDEN'), throwsA(isA<LedgerDbUnavailable>()));
      // Other brands are not affected.
      expect(await allKeys(db, 'AS'), isNotEmpty);
    });

    test('signalFor gives the compiled signal of a code, and none for the rest',
        () async {
      final IrBlasterDb db = open();
      final String hex =
          (await allKeys(db, 'BRENNAN', protocol: 'sony12')).first.hexcode;

      final LedgerSignal? signal = await db.signalFor('SONY12', hex);
      expect(signal!.pronto, startsWith('0000 '));
      expect(signal.play!.repeatPasses, 3);
      expect(await db.signalFor('SONY12', 'NOT A CODE'), isNull);
      expect(await db.signalFor('NEC', '00FF'), isNull);
      expect(await db.signalFor('NOT A PROTOCOL', '00'), isNull);
      expect(db.requiresSignal('Sharp'), isTrue);
      expect(db.requiresSignal('NEC'), isFalse);
      expect(db.requiresSignal('nope'), isFalse);
    });
  });

  group('how a question is read', () {
    test('a protocol is matched however it is spelled', () async {
      final IrBlasterDb db = open();

      final List<String> a = (await allKeys(db, 'B2B.TEST', protocol: 'RCA-38'))
          .map((IrDbKeyCandidate r) => r.label ?? '')
          .toList();
      expect(a, isNotEmpty);
      for (final String spelling in <String>[
        'rca_38',
        'RCA 38',
        ' Rca_38 ',
        'RCA_38'
      ]) {
        expect(
          (await allKeys(db, 'B2B.TEST', protocol: spelling))
              .map((IrDbKeyCandidate r) => r.label ?? '')
              .toList(),
          a,
          reason: spelling,
        );
      }
      expect(await allKeys(db, 'B2B.TEST', protocol: 'kaseikyo'), isEmpty);
      expect(await allKeys(db, 'B2B.TEST', protocol: '---'), isNotEmpty,
          reason: 'a spelling with no letters or digits is no filter');
    });

    test('blank and unknown arguments answer with nothing, as before',
        () async {
      final IrBlasterDb db = open();

      expect(await allKeys(db, ''), isEmpty);
      expect(await allKeys(db, '   '), isEmpty);
      expect(await allKeys(db, 'NO SUCH BRAND'), isEmpty);
      expect(await allKeys(db, 'BRENNAN', model: 'NO SUCH MODEL'), isEmpty);
      expect(await db.countCandidateKeys(brand: 'NO SUCH BRAND'), 0);
      expect(await db.listModelsDistinct(brand: ''), isEmpty);
      expect(await db.listModelsDistinct(brand: 'NO SUCH BRAND'), isEmpty);
      expect(await db.listProtocolsForBrand(''), isEmpty);
      expect(await db.listProtocolsForBrand('NO SUCH BRAND'), isEmpty);
      expect(await db.listProtocolsFor(brand: 'BRENNAN', model: ''), isEmpty);
      expect(
          await db.listProtocolsFor(brand: 'BRENNAN', model: 'NO SUCH MODEL'),
          isEmpty);
      expect(await db.brandContentHash('NO SUCH BRAND'), isNull);
    });

    test('a brand and a model are matched exactly after trimming', () async {
      final IrBlasterDb db = open();
      final String model =
          (await db.listModelsDistinct(brand: 'BRENNAN')).first;

      expect(await allKeys(db, ' BRENNAN ', model: ' $model '), isNotEmpty);
      expect(await allKeys(db, 'brennan'), isEmpty,
          reason: 'brands are exact, as `m.brand = ?` was');
    });

    test('limit and offset behave as LIMIT and OFFSET did', () async {
      final IrBlasterDb db = open();
      final List<IrDbKeyCandidate> all = await allKeys(db, 'BRENNAN');

      Future<List<IrDbKeyCandidate>> page(int limit, int offset) =>
          db.fetchCandidateKeys(
            brand: 'BRENNAN',
            quickWinsFirst: true,
            limit: limit,
            offset: offset,
          );
      expect((await page(3, 2)).map((IrDbKeyCandidate r) => r.hexcode).toList(),
          all.skip(2).take(3).map((IrDbKeyCandidate r) => r.hexcode).toList());
      expect(await page(0, 0), isEmpty);
      expect(await page(5, all.length), isEmpty);
      expect(await page(5, all.length + 100), isEmpty);
      expect(await page(5, -3), hasLength(5),
          reason: 'a negative offset is the start');
    });

    test('the hex prefix is a prefix, in any case, spaces ignored', () async {
      final IrBlasterDb db = open();
      final String hex =
          (await allKeys(db, 'AS', protocol: 'nec')).first.hexcode;

      Future<List<IrDbKeyCandidate>> withPrefix(String p) =>
          db.fetchCandidateKeys(
            brand: 'AS',
            quickWinsFirst: false,
            hexPrefixUpper: p,
            limit: 1 << 30,
          );
      final List<IrDbKeyCandidate> some =
          await withPrefix(hex.substring(0, 2).toLowerCase());
      expect(some, isNotEmpty);
      expect(
          some.every((IrDbKeyCandidate r) =>
              r.hexcode.startsWith(hex.substring(0, 2))),
          isTrue);
      expect(
          await withPrefix(
              ' ${hex.substring(0, 2)[0]} ${hex.substring(1, 2)} '),
          hasLength(some.length));
      expect(await withPrefix('ZZZZ'), isEmpty);
      expect(await withPrefix('  '), isNotEmpty, reason: 'blank is no prefix');
    });

    test('a search finds a word in the label or the hex, ignoring ASCII case',
        () async {
      final IrBlasterDb db = open();
      final List<IrDbKeyCandidate> all = await allKeys(db, 'DAEWOO');
      final IrDbKeyCandidate power = all.firstWhere(
        (IrDbKeyCandidate r) => (r.label ?? '').toUpperCase().contains('POWER'),
      );

      final List<IrDbKeyCandidate> found = await db.fetchCandidateKeys(
        brand: 'DAEWOO',
        quickWinsFirst: true,
        search: ' pOwEr ',
        limit: 1 << 30,
      );
      expect(found, isNotEmpty);
      expect(
          found.every((IrDbKeyCandidate r) =>
              (r.label ?? '').toUpperCase().contains('POWER') ||
              r.hexcode.toUpperCase().contains('POWER')),
          isTrue);
      final List<IrDbKeyCandidate> byHex = await db.fetchCandidateKeys(
        brand: 'DAEWOO',
        quickWinsFirst: true,
        search: power.hexcode.toLowerCase(),
        limit: 1 << 30,
      );
      expect(byHex.any((IrDbKeyCandidate r) => r.hexcode == power.hexcode),
          isTrue);
      // `%` and `_` in a label search are literal; in the hex half of the
      // search the old query never matched them.
      expect(
        (await db.fetchCandidateKeys(
          brand: 'ERA',
          quickWinsFirst: true,
          search: '%',
          limit: 1 << 30,
        ))
            .every((IrDbKeyCandidate r) => (r.label ?? '').contains('%')),
        isTrue,
      );
    });

    test('keys come in the quick-wins order when asked, else by label',
        () async {
      final IrBlasterDb db = open();

      final List<IrDbKeyCandidate> quick = await allKeys(db, 'DAEWOO');
      final List<IrDbKeyCandidate> plain =
          await allKeys(db, 'DAEWOO', quick: false);

      expect(quick, hasLength(plain.length));
      expect((quick.first.label ?? '').toUpperCase(), contains('POWER'));
      final List<String> labels = plain
          .map((IrDbKeyCandidate r) => (r.label ?? '').toUpperCase())
          .toList();
      final List<String> sorted = List<String>.of(labels)..sort();
      expect(labels, sorted);
    });

    test('brands and models list in NOCASE order, names compared as bytes',
        () async {
      final IrBlasterDb db = open();
      final List<String> brands = await db.listBrands(limit: 1 << 30);

      // Mixed-case names sit among the capitals, and the Cyrillic ones come
      // last: code point order, not locale order.
      expect(brands.indexOf('Citilux'), greaterThan(brands.indexOf('CHINA')));
      expect(brands.indexOf('Citilux'), lessThan(brands.indexOf('CITIZEN')));
      expect(brands.sublist(brands.length - 3),
          <String>['ZYXEL', 'СМОТРЁШКА', 'ЭРА']);
    });
  });

  group('the brand list and the protocol filters', () {
    test(
        'a protocol filter keeps the brands that have it, by the brand\'s own mask',
        () async {
      final IrBlasterDb db = open();

      final List<String> sony12 =
          await db.listBrands(protocolId: 'sony12', limit: 1 << 30);
      final List<String> all = await db.listBrands(limit: 1 << 30);

      expect(sony12, contains('BRENNAN'));
      expect(sony12, isNot(contains('AMCREST')));
      expect(sony12.length, lessThan(all.length));
      expect(
          await db.listBrands(protocolId: 'kaseikyo', limit: 1 << 30), isEmpty);
    });

    test('a brand\'s protocols come in UPPER(name) order', () async {
      final IrBlasterDb db = open();

      expect(await db.listProtocolsForBrand('BRENNAN'),
          <String>['SONY12', 'SONY15', 'SONY20']);
      final List<String> daewoo = await db.listProtocolsForBrand('DAEWOO');
      final List<String> sorted = List<String>.of(daewoo)
        ..sort(
            (String a, String b) => a.toUpperCase().compareTo(b.toUpperCase()));
      expect(daewoo, sorted);
    });

    test(
        'models filter by protocol: a model stays if any of its remotes has it',
        () async {
      final IrBlasterDb db = open();

      final List<String> withSony = await db.listModelsDistinct(
        brand: 'DAEWOO',
        protocolId: 'sony12',
        limit: 1 << 30,
      );
      final List<String> all =
          await db.listModelsDistinct(brand: 'DAEWOO', limit: 1 << 30);
      expect(withSony, isNotEmpty);
      expect(withSony.length, lessThan(all.length));
      for (final String m in withSony.take(5)) {
        expect(await db.listProtocolsFor(brand: 'DAEWOO', model: m),
            contains('SONY12'));
      }
    });
  });

  group('the power list', () {
    test('lists the codes with their protocol, and which need a signal',
        () async {
      final IrBlasterDb db = open();

      final List<IrDbPowerRow> rows = await db.powerRows();

      expect(rows.first.label, 'POWER');
      expect(rows.first.requiresSignal, isFalse);
      expect(rows.any((IrDbPowerRow r) => r.requiresSignal), isTrue);
      for (final IrDbPowerRow r in rows) {
        expect(r.requiresSignal, db.requiresSignal(r.protocol),
            reason: r.protocol);
        expect(r.rank, anyOf(0, 1));
      }
    });
  });

  group('when the ledger\'s data changes', () {
    test('the selections and the brand index are rebuilt for the new version',
        () async {
      DateTime now = DateTime.utc(2026, 10, 3, 12);
      final IrBlasterDb db = open(now: () => now);
      await allKeys(db, 'BRENNAN');
      final String before = db.dataVersion!;
      final int built = selectionsBuilt;

      now = now.add(const Duration(hours: 13));
      server.overrides['manifest.json'] =
          manifestWithDataVersion('abcabcabcabc');
      await db.ensureInitialized();

      expect(db.dataVersion, isNot(before));
      expect(db.dataVersion, 'abcabcabcabc');
      expect(await allKeys(db, 'BRENNAN'), isNotEmpty);
      expect(selectionsBuilt, built + 1);
      expect(server.count('brands.json'), 2);
    });

    test('brandContentHash is the hash the brand\'s models file gives',
        () async {
      final IrBlasterDb db = open();
      final String key = brandKey('BRENNAN');

      expect(
        await db.brandContentHash('BRENNAN'),
        (jsonDecode(utf8.decode(fixtureBytes('b/$key.m.json'))) as Map)['hash'],
      );
    });
  });
}
