import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/utils/remotes_io.dart';

// Two keys exactly as Remote Ledger compiles them, from
// build/pronto/sony/RMT-B118P.json and build/pronto/topping/RC-15A.json.
// Sony20 has no intro, so its whole frame is the repeat sequence. NEC1 puts
// its frame in the intro and the repeat ditto after it.
const String sonyPower =
    '0000 0068 0000 0015 0060 0018 0030 0018 0018 0018 0030 0018 0018 0018 '
    '0030 0018 0018 0018 0018 0018 0018 0018 0030 0018 0018 0018 0030 0018 '
    '0030 0018 0018 0018 0030 0018 0018 0018 0018 0018 0018 0018 0030 0018 '
    '0030 0018 0030 01F6';
const String nec1Power =
    '0000 006D 0022 0002 0157 00AC 0015 0015 0015 0015 0015 0015 0015 0040 '
    '0015 0015 0015 0015 0015 0015 0015 0040 0015 0040 0015 0040 0015 0040 '
    '0015 0015 0015 0040 0015 0040 0015 0040 0015 0015 0015 0015 0015 0015 '
    '0015 0015 0015 0040 0015 0040 0015 0015 0015 0015 0015 0015 0015 0040 '
    '0015 0040 0015 0040 0015 0015 0015 0015 0015 0040 0015 0040 0015 0040 '
    '0015 05E8 0157 0056 0015 0E49';

String ledgerRemote({
  required String manufacturer,
  required String model,
  required Map<String, Object> protocol,
  required Map<String, String> keys,
  int schemaVersion = 1,
}) {
  return jsonEncode(<String, Object>{
    'schemaVersion': schemaVersion,
    'manufacturer': manufacturer,
    'model': model,
    'protocol': protocol,
    'keys': <String, Object>{
      for (final entry in keys.entries)
        entry.key: <String, Object>{
          'candidates': <String, Object>{
            'primary': <String, Object>{
              'confidence': 'verified',
              'prontoHex': entry.value,
              'source': 'test fixture',
            },
          },
        },
    },
  });
}

ImportPreviewResult preview(String contents, {String filename = 'X.json'}) {
  return analyzeImportedText(
    contents,
    filename: filename,
    fallbackRemoteName: 'ImportedRemote',
    fallbackButtonLabel: 'Button',
  );
}

List<int> durations(String? rawData) =>
    rawData!.split(' ').map(int.parse).toList(growable: false);

void main() {
  test('A Remote Ledger remote imports under its manufacturer and model', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Sony',
        model: 'RMT-B118P',
        protocol: const <String, Object>{
          'name': 'Sony20',
          'carrierHz': 40000,
          'minSends': 3,
        },
        keys: const <String, String>{'KEY_POWER': sonyPower},
      ),
      filename: 'RMT-B118P.json',
    );

    expect(result.isSupported, isTrue);
    expect(result.formatLabel, 'Remote Ledger');
    final remote = result.remotes.single;
    expect(remote.name, 'Sony RMT-B118P');
    final button = remote.buttons.single;
    expect(button.image, 'KEY_POWER');
    // The protocol's own carrier, not the 39857 Hz the Pronto word rounds to.
    expect(button.frequency, 40000);
  });

  test('A code with no intro is sent minSends times', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Sony',
        model: 'RMT-B118P',
        protocol: const <String, Object>{'carrierHz': 40000, 'minSends': 3},
        keys: const <String, String>{'KEY_POWER': sonyPower},
      ),
    );

    final sent = durations(result.remotes.single.buttons.single.rawData);
    expect(sent, hasLength(42 * 3));
    final frame = sent.sublist(0, 42);
    expect(frame.take(2), <int>[2409, 602]);
    expect(sent.sublist(42, 84), frame);
    expect(sent.sublist(84), frame);
  });

  test('An intro is the first send, so one send leaves out the repeat', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Topping',
        model: 'RC-15A',
        protocol: const <String, Object>{
          'name': 'NEC1',
          'carrierHz': 38000,
          'minSends': 1,
        },
        keys: const <String, String>{'KEY_POWER': nec1Power},
      ),
    );

    final sent = durations(result.remotes.single.buttons.single.rawData);
    expect(sent, hasLength(68));
    expect(sent.take(2), <int>[9019, 4523]);
    expect(sent.last, 39759);
  });

  test('Each send after an intro is one more repeat sequence', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Topping',
        model: 'RC-15A',
        protocol: const <String, Object>{'carrierHz': 38000, 'minSends': 3},
        keys: const <String, String>{'KEY_POWER': nec1Power},
      ),
    );

    final sent = durations(result.remotes.single.buttons.single.rawData);
    expect(sent, hasLength(68 + 4 * 2));
    const ditto = <int>[9019, 2261, 552, 96164];
    expect(sent.sublist(68, 72), ditto);
    expect(sent.sublist(72), ditto);
  });

  test('A newer Remote Ledger schema is refused rather than guessed at', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Sony',
        model: 'RMT-B118P',
        protocol: const <String, Object>{'carrierHz': 40000, 'minSends': 3},
        keys: const <String, String>{'KEY_POWER': sonyPower},
        schemaVersion: 2,
      ),
    );

    expect(result.isSupported, isFalse);
    expect(result.formatLabel, 'Remote Ledger');
    expect(result.supportReason, contains('schema version 2'));
  });

  test('A two-burst code imports, as Canon RC-1 shutter releases are', () {
    // build/pronto/lirc/canon/RC-1_RC-5.json. Shorter than the six durations
    // the importer asks of text that only looks like Pronto.
    final result = preview(
      ledgerRemote(
        manufacturer: 'Canon',
        model: 'RC-1_RC-5',
        protocol: const <String, Object>{'carrierHz': 38000, 'minSends': 1},
        keys: const <String, String>{
          'KEY_S': '0000 006D 0000 0002 0015 0110 0015 0EDB',
        },
      ),
    );

    expect(result.isSupported, isTrue);
    expect(
      durations(result.remotes.single.buttons.single.rawData),
      <int>[552, 7152, 552, 100003],
    );
  });

  test('A key without a playable code is skipped, not the whole remote', () {
    final result = preview(
      ledgerRemote(
        manufacturer: 'Sony',
        model: 'RMT-B118P',
        protocol: const <String, Object>{'carrierHz': 40000, 'minSends': 3},
        keys: const <String, String>{
          'KEY_POWER': sonyPower,
          'KEY_BROKEN': 'not pronto',
        },
      ),
    );

    expect(result.isSupported, isTrue);
    expect(
      result.remotes.single.buttons.map((button) => button.image),
      <String>['KEY_POWER'],
    );
  });
}
