import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/ir_finder_prefs.dart';
import 'package:swiftremote/ir_finder/ir_finder_run_controller.dart';
import 'package:swiftremote/ir_finder/ir_finder_search.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';

Map<String, dynamic> _session({
  required int v,
  String mode = 'database',
  int currentOffset = 12,
  String? dataVersion,
  String? brandHash,
}) {
  return <String, dynamic>{
    'v': v,
    'mode': mode,
    'protocolId': 'sony12',
    'brand': 'SONY',
    'model': 'KDL-40',
    'delayMs': 500,
    'maxKeysToTest': 200,
    'bruteMaxAttempts': 200,
    'bruteAllCombinations': false,
    'bruteStrategy': 'sequential',
    'prefixRaw': '',
    'kaseikyoVendor': '2002',
    'onlySelectedProtocol': true,
    'quickWinsFirst': true,
    'attempted': currentOffset,
    'currentOffset': currentOffset,
    'bruteCursorHex': '0',
    'startedAtMs': 1700000000000,
    'paused': true,
    if (dataVersion != null) 'dataVersion': dataVersion,
    if (brandHash != null) 'brandHash': brandHash,
  };
}

Future<void> _store(Map<String, dynamic> session) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    IrFinderPrefs.sessionKey: jsonEncode(session),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the saved session', () {
    test('is version 3 and records the data its offset was counted over', () {
      expect(IrFinderSessionSnapshot.currentVersion, 3);
      final IrFinderSessionSnapshot s = IrFinderSessionSnapshot.fromJson(
        _session(v: 3, dataVersion: 'b7b18bba2dae', brandHash: 'a1b2c3'),
      );

      expect(s.dataVersion, 'b7b18bba2dae');
      expect(s.brandHash, 'a1b2c3');
      final IrFinderSessionSnapshot again =
          IrFinderSessionSnapshot.fromJson(s.toJson());
      expect(again.dataVersion, 'b7b18bba2dae');
      expect(again.brandHash, 'a1b2c3');
      expect(again.v, 3);
      expect(again.currentOffset, 12);
    });

    test('a database session from the bundled database is discarded on upgrade',
        () async {
      await _store(_session(v: 2));

      expect(await IrFinderPrefs.loadSession(), isNull);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(IrFinderPrefs.sessionKey), isFalse,
          reason: 'and forgotten, not just ignored');
    });

    test('so is one saved before sessions had a version at all', () async {
      final Map<String, dynamic> old = _session(v: 1)..remove('v');
      await _store(old);

      expect(await IrFinderPrefs.loadSession(), isNull);
    });

    test(
        'a brute force session from before is kept: its order never depended on a database',
        () async {
      await _store(_session(v: 2, mode: 'bruteforce', currentOffset: 40));

      final IrFinderSessionSnapshot? s = await IrFinderPrefs.loadSession();

      expect(s, isNotNull);
      expect(s!.mode, IrFinderMode.bruteforce);
      expect(s.currentOffset, 40);
    });

    test('a database session saved by this version is kept', () async {
      await _store(
          _session(v: 3, dataVersion: 'b7b18bba2dae', brandHash: 'a1b2c3'));

      final IrFinderSessionSnapshot? s = await IrFinderPrefs.loadSession();

      expect(s, isNotNull);
      expect(s!.mode, IrFinderMode.database);
      expect(s.brand, 'SONY');
      expect(s.model, 'KDL-40');
    });

    group('may be resumed', () {
      IrFinderSessionSnapshot snapshot({
        String? dataVersion,
        String? brandHash,
        int offset = 12,
        String mode = 'database',
      }) =>
          IrFinderSessionSnapshot.fromJson(_session(
            v: 3,
            mode: mode,
            currentOffset: offset,
            dataVersion: dataVersion,
            brandHash: brandHash,
          ));

      test('over the same ledger data', () {
        expect(
          snapshot(dataVersion: 'aaa', brandHash: 'h1')
              .isResumableWith(dataVersion: 'aaa', brandHash: 'zzz'),
          isTrue,
        );
      });

      test('when the data moved on but this brand did not', () {
        expect(
          snapshot(dataVersion: 'aaa', brandHash: 'h1')
              .isResumableWith(dataVersion: 'bbb', brandHash: 'h1'),
          isTrue,
        );
      });

      test('not when the brand\'s keys changed: the offset points elsewhere',
          () {
        expect(
          snapshot(dataVersion: 'aaa', brandHash: 'h1')
              .isResumableWith(dataVersion: 'bbb', brandHash: 'h2'),
          isFalse,
        );
        expect(
          snapshot(dataVersion: 'aaa', brandHash: 'h1')
              .isResumableWith(dataVersion: 'bbb', brandHash: null),
          isFalse,
        );
      });

      test(
          'not when it never recorded what it counted over, unless it never moved',
          () {
        expect(snapshot().isResumableWith(dataVersion: 'aaa', brandHash: 'h1'),
            isFalse);
        expect(
          snapshot(offset: 0)
              .isResumableWith(dataVersion: 'aaa', brandHash: 'h1'),
          isTrue,
        );
      });

      test('always, for brute force', () {
        expect(
          snapshot(mode: 'bruteforce')
              .isResumableWith(dataVersion: null, brandHash: null),
          isTrue,
        );
      });
    });
  });

  group('the run controller', () {
    IrFinderCandidate candidate() => const IrFinderCandidate(
          protocolId: 'nec',
          displayProtocol: 'NEC',
          displayCode: '00FF',
          params: <String, dynamic>{},
          source: IrFinderSource.database,
        );

    IrFinderRunController controller({
      required Future<IrFinderCandidate?> Function(IrFinderRunController) fetch,
    }) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      return IrFinderRunController(
        fetchCandidate: fetch,
        sendCandidate: (IrFinderCandidate c) async {},
      );
    }

    void configure(IrFinderRunController c,
        {String? dataVersion, String? brandHash}) {
      c.configure(
        dataVersion: dataVersion,
        brandHash: brandHash,
        mode: IrFinderMode.database,
        protocolId: 'sony12',
        delayMs: 500,
        maxKeysToTest: 100,
        bruteMaxAttempts: 10,
        bruteAllCombinations: false,
        bruteStrategy: IrFinderSearchStrategy.sequential,
        prefixRaw: '',
        kaseikyoVendor: '2002',
        onlySelectedProtocol: true,
        quickWinsFirst: true,
        brand: 'SONY',
        model: null,
      );
    }

    test('snapshots as version 3 with the data it runs over', () {
      final IrFinderRunController c =
          controller(fetch: (_) async => candidate());
      addTearDown(c.dispose);
      configure(c, dataVersion: 'b7b18bba2dae', brandHash: 'a1b2c3');

      final IrFinderSessionSnapshot s = c.snapshot();

      expect(s.v, 3);
      expect(s.dataVersion, 'b7b18bba2dae');
      expect(s.brandHash, 'a1b2c3');
    });

    test('a brute force session records no database data', () {
      final IrFinderRunController c =
          controller(fetch: (_) async => candidate());
      addTearDown(c.dispose);
      c.configure(
        dataVersion: 'b7b18bba2dae',
        brandHash: 'a1b2c3',
        mode: IrFinderMode.bruteforce,
        protocolId: 'nec',
        delayMs: 500,
        maxKeysToTest: 100,
        bruteMaxAttempts: 10,
        bruteAllCombinations: false,
        bruteStrategy: IrFinderSearchStrategy.sequential,
        prefixRaw: '',
        kaseikyoVendor: '2002',
        onlySelectedProtocol: true,
        quickWinsFirst: true,
        brand: null,
        model: null,
      );

      expect(c.snapshot().dataVersion, isNull);
      expect(c.snapshot().brandHash, isNull);
    });

    test('a fetch that throws stops the run instead of escaping from the timer',
        () async {
      final IrFinderRunController c = controller(
        fetch: (_) async => throw const LedgerDbUnavailable(
          LedgerDbFailure.offline,
          'no network',
        ),
      );
      addTearDown(c.dispose);
      configure(c);

      await c.start();
      await c.trigger();

      expect(c.running, isFalse);
      expect(c.lastError, isA<LedgerDbUnavailable>());
      expect(c.attempted, 0);
    });

    test('a step that throws is reported the same way', () async {
      final IrFinderRunController c = controller(
        fetch: (_) async => throw StateError('gone'),
      );
      addTearDown(c.dispose);
      configure(c);

      await c.step();

      expect(c.running, isFalse);
      expect(c.lastError, isA<StateError>());
    });

    test('a run that fetches carries on as before', () async {
      int fetched = 0;
      final IrFinderRunController c = controller(fetch: (_) async {
        fetched++;
        return candidate();
      });
      addTearDown(c.dispose);
      configure(c);

      await c.step();
      await c.step();

      expect(fetched, 2);
      expect(c.attempted, 2);
      expect(c.currentOffset, 2);
      expect(c.lastError, isNull);
      expect(c.running, isTrue);
    });
  });
}
