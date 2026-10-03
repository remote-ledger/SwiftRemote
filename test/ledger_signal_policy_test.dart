import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/ir_protocol_registry.dart';
import 'package:swiftremote/ir_finder/ir_finder_db_candidate.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/ledger_db/ledger_errors.dart';
import 'package:swiftremote/ledger_db/ledger_models.dart';
import 'package:swiftremote/utils/db_button_import.dart';
import 'package:swiftremote/utils/ir.dart';
import 'package:swiftremote/utils/ledger_signal.dart';
import 'package:swiftremote/utils/remote.dart';

import 'support/ledger_fixtures.dart';

/// The ten protocols whose database codes the app's own hex decoding reads
/// differently from the wire. They are data (the manifest says so); this list
/// is only here to hold the manifest to what the ledger's analysis found.
const Set<String> _theTen = <String>{
  'SONY12', 'SONY15', 'SONY20', 'Pioneer', 'JVC', 'Sharp', 'Denon',
  'Thomson7', 'Proton', 'RCC2026', //
};

/// A fixture brand that has codes of each of the ten.
const Map<String, String> _brandOf = <String, String>{
  'SONY12': 'BRENNAN',
  'SONY15': 'BRENNAN',
  'SONY20': 'BRENNAN',
  'Pioneer': 'AMCREST',
  'JVC': 'VOLVO',
  'Sharp': 'STRIM(AMINO)',
  'Denon': 'UNIDEN',
  'Thomson7': 'B2B.TEST',
  'Proton': 'SATEC',
  'RCC2026': 'JIN LIPU',
};

void main() {
  late Directory dir;
  late IrBlasterDb db;

  setUp(() async {
    dir = await tempCacheDir();
    db = IrBlasterDb.forTesting(fixtureLedgerDb(FakeLedgerServer(), dir));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<List<IrDbKeyCandidate>> keysOf(String protocol) =>
      db.fetchCandidateKeys(
        brand: _brandOf[protocol]!,
        selectedProtocolId: protocol,
        quickWinsFirst: true,
        limit: 1 << 30,
      );

  /// The candidate the Signal Tester builds, with decoders that must not run.
  IrFinderCandidate candidateWithoutDecoders(IrDbKeyCandidate row) {
    return candidateForDbRow(
      row,
      brand: row.brand,
      model: row.model,
      displayName: (String id) => id.toUpperCase(),
      buildParams: (String id, String hex) =>
          throw StateError('The hex decoder was reached for $id $hex'),
      fitHex: (String id, String hex) => hex,
    );
  }

  group('which protocols are played from the signal', () {
    test('the manifest names exactly the ten the ledger found', () async {
      await db.ensureInitialized();

      final Set<String> fromRows = <String>{};
      for (final String brand in _brandOf.values.toSet()) {
        for (final IrDbKeyCandidate r in await db.fetchCandidateKeys(
          brand: brand,
          quickWinsFirst: false,
          limit: 1 << 30,
        )) {
          if (r.requiresSignal) fromRows.add(r.protocol);
        }
      }

      expect(fromRows, _theTen);
      for (final String p in _theTen) {
        expect(db.requiresSignal(p), isTrue, reason: p);
      }
    });
  });

  group('a divergent protocol\'s row never reaches the hex decoders', () {
    test('every code of the ten becomes a raw button of its signal', () async {
      int checked = 0;
      for (final String protocol in _theTen) {
        final List<IrDbKeyCandidate> rows = await keysOf(protocol);
        expect(rows, isNotEmpty, reason: protocol);
        for (final IrDbKeyCandidate row in rows) {
          final IRButton? button = buildButtonFromDbRow(row);

          expect(button, isNotNull, reason: '$protocol ${row.hexcode}');
          expect(button!.protocol, isNull, reason: protocol);
          expect(button.protocolParams, isNull, reason: protocol);
          expect(button.code, isNull, reason: protocol);
          final LedgerPlayback press = row.signal!.playback()!;
          expect(button.rawData, press.rawData,
              reason: '$protocol ${row.hexcode}');
          expect(button.frequency, press.frequencyHz, reason: protocol);
          checked++;
        }
      }
      expect(checked, greaterThan(150));
    });

    test(
        'the Signal Tester candidate plays the signal and builds no parameters',
        () async {
      for (final String protocol in _theTen) {
        for (final IrDbKeyCandidate row in (await keysOf(protocol)).take(25)) {
          final IrFinderCandidate c = candidateWithoutDecoders(row);

          expect(c.raw, isNotNull, reason: protocol);
          expect(c.raw!.pattern, row.signal!.playback()!.pattern);
          expect(c.params, isEmpty);
          expect(c.dbRemoteId, row.remoteId);
          expect(c.dbLabel, row.label);
          expect(c.source, IrFinderSource.database);
        }
      }
    });

    test('without its signal such a row is not decoded instead', () {
      const IrDbKeyCandidate pioneer = IrDbKeyCandidate(
        id: 1,
        protocol: 'Pioneer',
        hexcode: 'A57AA5E0',
        label: 'POWER',
        requiresSignal: true,
      );

      expect(buildButtonFromDbRow(pioneer), isNull);
      expect(() => candidateWithoutDecoders(pioneer),
          throwsA(isA<LedgerSignalUnavailable>()));
    });

    test('a row of any other protocol is decoded as it always was', () async {
      final List<IrDbKeyCandidate> rows = await db.fetchCandidateKeys(
        brand: 'FRITZU',
        selectedProtocolId: 'rc5',
        quickWinsFirst: true,
        limit: 1 << 30,
      );
      expect(rows, isNotEmpty);

      final IRButton button = buildButtonFromDbRow(rows.first)!;
      expect(button.protocol, 'rc5');
      expect(button.protocolParams, isNotEmpty);
      expect(button.rawData, isNull);
      expect(
        () => candidateWithoutDecoders(rows.first),
        throwsA(isA<StateError>()),
        reason: 'the decoder is what builds its candidate',
      );
    });

    test('the signal differs from what the app\'s own decoding would send',
        () async {
      // The reason for the policy: for these protocols the two disagree.
      int differing = 0;
      int compared = 0;
      for (final String protocol in <String>[
        'SONY12',
        'SONY15',
        'SONY20',
        'Pioneer'
      ]) {
        for (final IrDbKeyCandidate row in (await keysOf(protocol)).take(40)) {
          final String id = protocol.toLowerCase();
          final Map<String, dynamic> params;
          try {
            params = IrFinderParams.buildParamsForProtocol(id, row.hexcode);
          } catch (_) {
            continue;
          }
          final List<int> decoded =
              IrProtocolRegistry.encoderFor(id).encode(params).pattern;
          final List<int> wire = row.signal!.playback()!.pattern;
          compared++;
          if (decoded.length != wire.length ||
              Iterable<int>.generate(wire.length)
                  .any((int i) => (decoded[i] - wire[i]).abs() > 80)) {
            differing++;
          }
        }
      }
      expect(compared, greaterThan(20));
      expect(differing, greaterThan(0));
    });
  });

  group('how one press is played', () {
    ProntoSequences sequencesOf(IrDbKeyCandidate row) =>
        tryParseProntoSequences(row.signal!.pronto, minDurations: 2)!;

    test('Sharp and Denon play three frames: the intro and the repeat sequence',
        () async {
      for (final String protocol in <String>['Sharp', 'Denon']) {
        final List<IrDbKeyCandidate> rows = await keysOf(protocol);
        for (final IrDbKeyCandidate row in rows.take(30)) {
          final ProntoSequences code = sequencesOf(row);
          final List<int> press = row.signal!.playback()!.pattern;

          // One frame of 16 burst pairs in the intro, two in the repeat.
          expect(code.intro, hasLength(32), reason: protocol);
          expect(code.repeat, hasLength(64), reason: protocol);
          expect(press, hasLength(96), reason: protocol);
          expect(press, <int>[...code.intro, ...code.repeat]);
          // The rule for a ledger remote file, minSends 1, would play one.
          expect(remoteLedgerSends(code, 1), hasLength(32), reason: protocol);
        }
        expect(rows.first.signal!.play!.rule, 'full-signal');
      }
    });

    test('Sony plays its frame three times, Thomson7 twice, Proton once',
        () async {
      for (final (String protocol, int times) in <(String, int)>[
        ('SONY12', 3),
        ('SONY15', 3),
        ('SONY20', 3),
        ('Thomson7', 2),
        ('Proton', 1),
      ]) {
        final IrDbKeyCandidate row = (await keysOf(protocol)).first;
        final ProntoSequences code = sequencesOf(row);

        expect(code.intro, isEmpty, reason: protocol);
        expect(row.signal!.playback()!.pattern,
            hasLength(code.repeat.length * times),
            reason: protocol);
      }
    });

    test(
        'Pioneer and JVC play the intro alone, RCC2026 the intro and one repeat',
        () async {
      for (final String protocol in <String>['Pioneer', 'JVC']) {
        final IrDbKeyCandidate row = (await keysOf(protocol)).first;
        expect(row.signal!.playback()!.pattern, sequencesOf(row).intro,
            reason: protocol);
      }
      final IrDbKeyCandidate rcc = (await keysOf('RCC2026')).first;
      final ProntoSequences code = sequencesOf(rcc);
      expect(rcc.signal!.playback()!.pattern,
          <int>[...code.intro, ...code.repeat]);
    });

    test(
        'the count is the one the database states, and equals the ledger rule except '
        'where it says full-signal', () async {
      for (final String protocol in _theTen) {
        final IrDbKeyCandidate row = (await keysOf(protocol)).first;
        final LedgerPlay play = row.signal!.play!;
        final ProntoSequences code = sequencesOf(row);

        if (play.rule == 'ledger') {
          expect(play.repeatPasses, play.helperRepeatPasses, reason: protocol);
          expect(row.signal!.playback()!.pattern,
              remoteLedgerSends(code, row.signal!.minSends!),
              reason: protocol);
        } else {
          expect(<String>{'Sharp', 'Denon'}, contains(protocol));
          expect(play.repeatPasses, greaterThan(play.helperRepeatPasses));
        }
      }
    });

    test('every press is playable: positive durations, a carrier in range',
        () async {
      for (final String protocol in _theTen) {
        for (final IrDbKeyCandidate row in await keysOf(protocol)) {
          final LedgerPlayback press = row.signal!.playback()!;
          expect(press.pattern.every((int d) => d > 0), isTrue,
              reason: protocol);
          expect(press.pattern.length.isEven, isTrue, reason: protocol);
          expect(press.frequencyHz,
              inInclusiveRange(kMinIrFrequencyHz, kMaxIrFrequencyHz),
              reason: protocol);
        }
      }
    });
  });

  group('saved hits', () {
    test(
        'a hit saved with the old reading keeps the parameters it was tested with',
        () {
      final IrFinderHit old = IrFinderHit(
        savedAt: DateTime(2026),
        protocolId: 'sony12',
        protocolName: 'SONY12',
        code: 'A90',
        source: IrFinderSource.database,
        dbBrand: 'SONY',
        dbLabel: 'POWER',
        protocolParams: const <String, dynamic>{
          'address': '15',
          'command': '10'
        },
      );

      final IRButton button = buttonForHit(old);

      expect(button.protocol, 'sony12');
      expect(button.protocolParams,
          <String, dynamic>{'address': '15', 'command': '10'});
      expect(button.rawData, isNull);
      expect(button.image, 'POWER');
    });

    test('a hit found as a signal becomes a raw button of that press',
        () async {
      final IrDbKeyCandidate row = (await keysOf('SONY12')).first;
      final IrFinderCandidate found = candidateWithoutDecoders(row);
      final IrFinderHit hit = IrFinderHit(
        savedAt: DateTime(2026),
        protocolId: found.protocolId,
        protocolName: found.displayProtocol,
        code: found.displayCode,
        source: found.source,
        dbLabel: found.dbLabel,
        rawData: found.raw!.rawData,
        rawFrequencyHz: found.raw!.frequencyHz,
      );

      final IRButton button = buttonForHit(hit);

      expect(button.protocol, isNull);
      expect(button.protocolParams, isNull);
      expect(button.rawData, found.raw!.rawData);
      expect(button.frequency, found.raw!.frequencyHz);
      expect(hit.rawPlayback!.pattern, found.raw!.pattern);
    });

    test(
        'a hit whose signal cannot be read is refused, not rebuilt from its hex',
        () {
      final IrFinderHit hit = IrFinderHit(
        savedAt: DateTime(2026),
        protocolId: 'sony12',
        protocolName: 'SONY12',
        code: 'A90',
        source: IrFinderSource.database,
        rawData: 'not numbers',
        rawFrequencyHz: 40000,
      );

      expect(hit.rawPlayback, isNull);
      expect(() => buttonForHit(hit), throwsStateError);
    });
  });
}
