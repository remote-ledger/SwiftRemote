/// How a Pronto code compiled by Remote Ledger
/// (github.com/remote-ledger/remote-ledger.github.io) becomes the burst
/// pattern the transmitter plays.
///
/// Two places need it: a Remote Ledger file imported from the Remote Ledger screen
/// (`remotes_io.dart`), and the IR code database the ledger publishes for the
/// protocols whose database codes the app's own decoders read differently from
/// the wire (`lib/ledger_db/`). Both follow the one rule below, so a key
/// sounds the same however it reached the app.
library;

/// A Pronto code's two burst sequences in microseconds: [intro] is sent once
/// and [repeat] for as long as the button is held. Either may be empty, but
/// not both.
class ProntoSequences {
  final int frequencyHz;
  final List<int> intro;
  final List<int> repeat;
  const ProntoSequences({
    required this.frequencyHz,
    required this.intro,
    required this.repeat,
  });
}

/// [minDurations] guards text that merely looks like Pronto, where four hex
/// words are weak evidence. A source known to hold Pronto can accept less:
/// Canon's RC-1 is two bursts 7 ms apart, and nothing longer.
ProntoSequences? tryParseProntoSequences(
  String payload, {
  int minDurations = 6,
}) {
  final cleaned = payload.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  if (cleaned.isEmpty) return null;

  final tokens =
      cleaned.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  if (tokens.length < 6) return null;

  bool looksHex = true;
  for (final t in tokens.take(4)) {
    if (!RegExp(r'^[0-9A-Fa-f]{4}$').hasMatch(t)) {
      looksHex = false;
      break;
    }
  }
  if (!looksHex) return null;

  final List<int> words = <int>[];
  for (final t in tokens) {
    final v = int.tryParse(t, radix: 16);
    if (v == null) return null;
    words.add(v);
  }

  final int type = words[0];
  final int freqWord = words[1];
  if (type != 0x0000 && type != 0x0100) return null;
  if (freqWord <= 0) return null;

  final int seq1 = words[2];
  final int seq2 = words[3];
  final int totalPairs = (seq1 + seq2) * 2;
  final int requiredWords = 4 + totalPairs;
  if (words.length < requiredWords) return null;

  final double carrierPeriodUs = freqWord * 0.241246;
  if (carrierPeriodUs <= 0) return null;

  final int freqHz = (1000000.0 / carrierPeriodUs).round().clamp(10000, 200000);
  final List<int> durations = <int>[];

  for (int i = 4; i < requiredWords; i++) {
    final int w = words[i];
    if (w <= 0) return null;
    final int us = (w * carrierPeriodUs).round();
    if (us <= 0) return null;
    durations.add(us);
  }

  if (durations.length < minDurations) return null;
  final int introLength = seq1 * 2;
  return ProntoSequences(
    frequencyHz: freqHz,
    intro: durations.sublist(0, introLength),
    repeat: durations.sublist(introLength),
  );
}

/// Lays out every send a button needs, because a raw button is played once.
///
/// Remote Ledger compiles a code's first send as the Pronto intro and the
/// sends after it as the repeat, and leaves `protocol.minSends` for the
/// player to honour rather than multiplying the repeat into the Pronto
/// string. The intro, when there is one, is the first send: an NEC code sent
/// once is its frame without the repeat ditto, while a Sony code has no intro
/// and is its frame three times.
///
/// This is the rule for a remote file, whose protocol block carries
/// `minSends`. The IR code database states its own count per protocol (see
/// [ledgerPlayback]).
List<int> remoteLedgerSends(ProntoSequences code, int sends) {
  final int repeats = code.intro.isEmpty ? sends : sends - 1;
  return <int>[
    ...code.intro,
    for (int i = 0; i < repeats; i++) ...code.repeat,
  ];
}

/// One key press: a carrier and the microsecond durations, mark first, that
/// make it up. Played once, as a raw signal.
class LedgerPlayback {
  final int frequencyHz;
  final List<int> pattern;
  const LedgerPlayback({required this.frequencyHz, required this.pattern});

  /// The durations as the space-separated text a raw button stores.
  String get rawData => pattern.join(' ');
}

/// The press the IR code database describes for [pronto]: the intro once,
/// then the repeat sequence [repeatPasses] times. The database states that
/// count per protocol (`play.repeatPasses`), because the right number is not
/// the same everywhere: it is `minSends` for Sony, where the intro is empty
/// and a press is the frame three times, but one pass of the repeat for Sharp
/// and Denon, whose second and third frames live in the repeat sequence.
///
/// The carrier is [carrierHz] when it is a usable one, and the Pronto code's
/// own frequency word otherwise (the database leaves it out where a protocol
/// has none of its own).
///
/// Null when [pronto] is not a Pronto code, or when the press would be empty.
LedgerPlayback? ledgerPlayback(
  String pronto, {
  required int repeatPasses,
  int? carrierHz,
}) {
  final ProntoSequences? code = tryParseProntoSequences(
    pronto,
    minDurations: 2,
  );
  if (code == null) return null;
  final int passes = repeatPasses < 0 ? 0 : repeatPasses;
  final List<int> pattern = <int>[
    ...code.intro,
    for (int i = 0; i < passes; i++) ...code.repeat,
  ];
  if (pattern.isEmpty) return null;
  final int frequency =
      carrierHz != null && carrierHz >= 10000 && carrierHz <= 200000
          ? carrierHz
          : code.frequencyHz;
  return LedgerPlayback(frequencyHz: frequency, pattern: pattern);
}
