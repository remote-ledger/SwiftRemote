import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/utils/ledger_signal.dart';

/// Frequency word 0x0068 is a 25.09 us carrier period (39,856 Hz); every
/// duration word below is that many carrier cycles.
const String _introAndRepeat =
    // Two burst pairs of intro, one of repeat.
    '0000 0068 0002 0001 0010 0020 0030 0040 0050 0060';
const String _repeatOnly =
    // No intro: the repeat sequence alone is the frame, as for Sony.
    '0000 0068 0000 0003 0060 0018 0018 0018 0018 0464';

void main() {
  group('tryParseProntoSequences', () {
    test('splits a code into its intro and its repeat sequence', () {
      final ProntoSequences code = tryParseProntoSequences(_introAndRepeat)!;

      expect(code.intro, hasLength(4));
      expect(code.repeat, hasLength(2));
      expect(code.frequencyHz, 39857);
      // 0x10 cycles of 25.0896 us, rounded.
      expect(code.intro.first, (0x10 * 0.241246 * 0x68).round());
    });

    test('reads a code with no intro as its repeat sequence alone', () {
      final ProntoSequences code = tryParseProntoSequences(_repeatOnly)!;

      expect(code.intro, isEmpty);
      expect(code.repeat, hasLength(6));
    });

    test('refuses text that is not a Pronto code', () {
      expect(tryParseProntoSequences(''), isNull);
      expect(tryParseProntoSequences('not pronto at all'), isNull);
      // Declares three burst pairs and carries two.
      expect(
        tryParseProntoSequences('0000 0068 0002 0001 0010 0020 0030 0040'),
        isNull,
      );
      // A zero duration word cannot be played.
      expect(
        tryParseProntoSequences('0000 0068 0001 0000 0000 0020'),
        isNull,
      );
    });
  });

  group('remoteLedgerSends (a remote file, by minSends)', () {
    test('plays the intro once and minSends - 1 repeats after it', () {
      final ProntoSequences code = tryParseProntoSequences(_introAndRepeat)!;

      expect(remoteLedgerSends(code, 1), code.intro);
      expect(remoteLedgerSends(code, 3), <int>[
        ...code.intro,
        ...code.repeat,
        ...code.repeat,
      ]);
    });

    test('plays an empty-intro code minSends times', () {
      final ProntoSequences code = tryParseProntoSequences(_repeatOnly)!;

      expect(remoteLedgerSends(code, 3), <int>[
        ...code.repeat,
        ...code.repeat,
        ...code.repeat,
      ]);
    });
  });

  group('ledgerPlayback (the IR code database, by repeatPasses)', () {
    test('plays the intro once, then the repeat repeatPasses times', () {
      final ProntoSequences code = tryParseProntoSequences(_introAndRepeat)!;

      final LedgerPlayback one =
          ledgerPlayback(_introAndRepeat, repeatPasses: 1)!;
      expect(one.pattern, <int>[...code.intro, ...code.repeat]);

      final LedgerPlayback two =
          ledgerPlayback(_introAndRepeat, repeatPasses: 2)!;
      expect(two.pattern, <int>[...code.intro, ...code.repeat, ...code.repeat]);
    });

    test('differs from the minSends rule where the database says so', () {
      // Sharp and Denon have minSends 1, which plays the intro alone, and
      // repeatPasses 1, which adds the repeat sequence that carries the
      // other frames.
      final ProntoSequences code = tryParseProntoSequences(_introAndRepeat)!;

      expect(remoteLedgerSends(code, 1), hasLength(4));
      expect(
        ledgerPlayback(_introAndRepeat, repeatPasses: 1)!.pattern,
        hasLength(6),
      );
    });

    test('plays only the intro when there are no repeat passes', () {
      final ProntoSequences code = tryParseProntoSequences(_introAndRepeat)!;

      expect(
        ledgerPlayback(_introAndRepeat, repeatPasses: 0)!.pattern,
        code.intro,
      );
    });

    test('plays an empty-intro code as the repeat, repeatPasses times', () {
      final ProntoSequences code = tryParseProntoSequences(_repeatOnly)!;

      expect(
        ledgerPlayback(_repeatOnly, repeatPasses: 3)!.pattern,
        <int>[...code.repeat, ...code.repeat, ...code.repeat],
      );
    });

    test('has nothing to play for an empty press or a bad code', () {
      expect(ledgerPlayback(_repeatOnly, repeatPasses: 0), isNull);
      expect(ledgerPlayback('', repeatPasses: 1), isNull);
      expect(ledgerPlayback('zzzz', repeatPasses: 1), isNull);
    });

    test('uses the stated carrier, else the one the Pronto code carries', () {
      expect(
        ledgerPlayback(_introAndRepeat, repeatPasses: 1, carrierHz: 40000)!
            .frequencyHz,
        40000,
      );
      expect(
        ledgerPlayback(_introAndRepeat, repeatPasses: 1)!.frequencyHz,
        39857,
      );
      // Out of any plausible range: ignore it rather than transmit it.
      expect(
        ledgerPlayback(_introAndRepeat, repeatPasses: 1, carrierHz: 5)!
            .frequencyHz,
        39857,
      );
    });

    test('writes the pattern as the text a raw button stores', () {
      final LedgerPlayback p =
          ledgerPlayback(_repeatOnly, repeatPasses: 1)!;

      expect(p.rawData, p.pattern.join(' '));
      expect(p.rawData.split(' '), hasLength(6));
    });
  });
}
