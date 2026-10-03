import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/ir_protocol_registry.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/universal_power/curated_power_patterns.dart';
import 'package:swiftremote/universal_power/power_code.dart';
import 'package:swiftremote/universal_power/power_code_repository.dart';
import 'package:swiftremote/universal_power/power_params.dart';
import 'package:swiftremote/universal_power/universal_power_controller.dart';
import 'package:swiftremote/utils/ir.dart' show platform;
import 'package:swiftremote/utils/ledger_signal.dart';

import 'support/ledger_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeLedgerServer server;
  late IrBlasterDb db;
  late List<MethodCall> sent;

  setUp(() async {
    dir = await tempCacheDir();
    server = FakeLedgerServer();
    db = IrBlasterDb.forTesting(fixtureLedgerDb(server, dir));
    sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (MethodCall call) async {
      sent.add(call);
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, null);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  PowerCode powerCodeOf(IrDbKeyCandidate r) => PowerCode(
        protocolId: r.protocol.toLowerCase().replaceAll('-', '_'),
        hexCode: r.hexcode,
        label: r.label ?? '',
        brand: r.brand,
        model: r.model,
        requiresSignal: r.requiresSignal,
        signal: r.signal,
      );

  group('sending a code', () {
    test(
        'a Pioneer or Sony code is played from its signal, not its decoded hex',
        () async {
      for (final (String brand, String protocol) in <(String, String)>[
        ('AMCREST', 'Pioneer'),
        ('BRENNAN', 'SONY12'),
      ]) {
        final IrDbKeyCandidate row = (await db.fetchCandidateKeys(
          brand: brand,
          selectedProtocolId: protocol,
          quickWinsFirst: true,
          limit: 1,
        ))
            .single;
        final PowerCode code = powerCodeOf(row);
        sent.clear();
        final UniversalPowerController controller = UniversalPowerController();

        await controller
            .start(queue: <PowerCode>[code], delayMs: 400, loop: false);
        await controller.stop();

        expect(controller.lastError, isNull, reason: protocol);
        expect(sent, hasLength(1), reason: protocol);
        expect(sent.single.method, 'transmitRaw');
        final LedgerPlayback press = row.signal!.playback()!;
        expect(sent.single.arguments['frequency'], press.frequencyHz);
        expect(sent.single.arguments['list'], press.pattern);
        // What the app's own decoding of the same hex would have sent is not
        // what went out.
        final String id = protocol.toLowerCase();
        final decoded = IrProtocolRegistry.encoderFor(id)
            .encode(
                buildParamsForProtocol(protocolId: id, codeHex: row.hexcode))
            .pattern;
        expect(sent.single.arguments['list'], isNot(decoded), reason: protocol);
      }
    });

    test('a code that needs its signal and has none is blocked, not decoded',
        () async {
      final UniversalPowerController controller = UniversalPowerController();

      await controller.start(
        queue: const <PowerCode>[
          PowerCode(
            protocolId: 'pioneer',
            hexCode: 'A57AA5E0',
            label: 'POWER',
            requiresSignal: true,
          ),
        ],
        delayMs: 400,
        loop: false,
      );
      await controller.stop();

      expect(sent, isEmpty, reason: 'nothing was transmitted');
      expect(controller.lastError, isA<LedgerSignalUnavailable>());
    });

    test('a code of a protocol the app reads as the wire is still decoded',
        () async {
      // NEC rather than RC5, whose encoder flips a toggle bit on every call.
      final IrDbKeyCandidate row = (await db.fetchCandidateKeys(
        brand: 'AS',
        selectedProtocolId: 'nec',
        quickWinsFirst: true,
        limit: 1,
      ))
          .single;
      expect(row.requiresSignal, isFalse);
      final UniversalPowerController controller = UniversalPowerController();

      await controller.start(
        queue: <PowerCode>[powerCodeOf(row)],
        delayMs: 400,
        loop: false,
      );
      await controller.stop();

      expect(controller.lastError, isNull);
      expect(sent, hasLength(1));
      final decoded = IrProtocolRegistry.encoderFor('nec')
          .encode(
              buildParamsForProtocol(protocolId: 'nec', codeHex: row.hexcode))
          .pattern;
      expect(sent.single.arguments['list'], decoded);
    });
  });

  group('the queue for all brands', () {
    test('is the curated patterns, then the ledger\'s power list in its order',
        () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes =
          await repo.loadAllPowerCodes(maxCodes: 5000);

      final int curated = curatedPowerPatterns.length;
      expect(codes.take(curated).every((PowerCode c) => c.rawPattern != null),
          isTrue);
      expect(codes.skip(curated).every((PowerCode c) => c.rawPattern == null),
          isTrue);
      final List<IrDbPowerRow> rows = await db.powerRows();
      expect(codes[curated].hexCode, rows.first.hexcode);
      expect(codes[curated].label, rows.first.label);
      // Popularity order is kept: the list's codes appear in its order.
      final List<String> order = rows
          .map((IrDbPowerRow r) => '${r.protocol.toLowerCase()}|${r.hexcode}')
          .toList();
      final List<String> got = codes
          .skip(curated)
          .map((PowerCode c) => '${c.protocolId}|${c.hexCode}')
          .toList();
      int last = -1;
      for (final String g in got) {
        final int at = order.indexOf(g);
        expect(at, greaterThan(last));
        last = at;
      }
    });

    test('lists each code once and reaches far past the old 67 brands',
        () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes =
          await repo.loadAllPowerCodes(maxCodes: 5000);

      final Set<String> seen = codes
          .where((PowerCode c) => c.rawPattern == null)
          .map((PowerCode c) => '${c.protocolId}|${c.hexCode}|${c.label}')
          .toSet();
      expect(seen, hasLength(codes.length - curatedPowerPatterns.length));
      expect(codes.length, greaterThan(curatedPowerPatterns.length + 50));
    });

    test('plays a code of the ten from its signal, one load per protocol',
        () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes =
          await repo.loadAllPowerCodes(maxCodes: 5000);

      final List<PowerCode> viaSignal =
          codes.where((PowerCode c) => c.requiresSignal).toList();
      expect(viaSignal, isNotEmpty);
      for (final PowerCode c in viaSignal) {
        expect(c.signal, isNotNull, reason: '${c.protocolId} ${c.hexCode}');
        expect(c.signal!.hexcode, c.hexCode);
        expect(c.signal!.playback(), isNotNull);
      }
      expect(
          codes.where((PowerCode c) => !c.requiresSignal && c.signal != null),
          isEmpty);
      for (final String p
          in server.requests.where((String r) => r.startsWith('s/'))) {
        expect(server.count(p), 1);
      }
      expect(repo.skippedSignalProtocols, isEmpty);
    });

    test('leaves out the codes whose signal cannot be had, and says which',
        () async {
      server.broken.add('s/Sharp.json');
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes =
          await repo.loadAllPowerCodes(maxCodes: 5000);

      expect(repo.skippedSignalProtocols, <String>{'Sharp'});
      expect(codes.where((PowerCode c) => c.protocolId == 'sharp'), isEmpty);
      expect(
          codes.where((PowerCode c) => c.protocolId == 'sony12'), isNotEmpty);
      // Asked once, not once per code.
      expect(server.count('s/Sharp.json'), 1);
    });

    test('honours the depth and the cap', () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> rank0 =
          await repo.loadAllPowerCodes(depth: 1, maxCodes: 5000);
      final List<PowerCode> rank1 =
          await repo.loadAllPowerCodes(depth: 2, maxCodes: 5000);
      final List<PowerCode> capped = await repo.loadAllPowerCodes(maxCodes: 40);

      expect(rank0.length, lessThan(rank1.length));
      expect(
          rank0
              .where((PowerCode c) => c.rawPattern == null)
              .every((PowerCode c) => powerLabelRank(c.label) == 0),
          isTrue);
      expect(capped, hasLength(40));
    });

    test('says when the list cannot be had at all', () async {
      final FakeLedgerServer offline = FakeLedgerServer()..offline = true;
      final PowerCodeRepository repo = PowerCodeRepository(
        db: IrBlasterDb.forTesting(fixtureLedgerDb(offline, dir)),
      );

      await expectLater(
          repo.loadAllPowerCodes(), throwsA(isA<LedgerDbUnavailable>()));
    });
  });

  group('the queue for one brand', () {
    test('lists each code once: a brand\'s models no longer repeat it',
        () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes =
          await repo.loadPowerCodes(brand: 'DAEWOO', maxCodes: 5000);

      expect(codes, isNotEmpty);
      final Set<String> seen = codes
          .map((PowerCode c) => '${c.protocolId}|${c.hexCode}|${c.label}')
          .toSet();
      expect(seen, hasLength(codes.length));
      expect(
          codes.every((PowerCode c) => powerLabelRank(c.label) <= 1), isTrue);
    });

    test('carries the signal of a code of the ten', () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes = await repo.loadPowerCodes(brand: 'BRENNAN');

      expect(codes, isNotEmpty);
      expect(codes.every((PowerCode c) => c.requiresSignal && c.signal != null),
          isTrue);
    });

    test('puts a curated pattern first for a brand that has one', () async {
      final PowerCodeRepository repo = PowerCodeRepository(db: db);

      final List<PowerCode> codes = await repo.loadPowerCodes(brand: 'Sony');

      expect(codes.first.rawPattern, isNotNull);
    });

    test('fails when the brand cannot be had', () async {
      final FakeLedgerServer offline = FakeLedgerServer();
      final IrBlasterDb fresh =
          IrBlasterDb.forTesting(fixtureLedgerDb(offline, dir));
      await fresh.ensureInitialized();
      offline.offline = true;

      await expectLater(
        PowerCodeRepository(db: fresh).loadPowerCodes(brand: 'DAEWOO'),
        throwsA(isA<LedgerDbUnavailable>()),
      );
    });
  });
}
