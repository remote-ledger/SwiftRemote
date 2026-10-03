import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/protocols/rc5.dart';

void main() {
  test('RC5 supports the field bit used by 7-bit commands', () {
    const encoder = Rc5ProtocolEncoder();
    final result = encoder.encode(<String, dynamic>{
      'address': '00',
      'command': '40',
      'toggle': false,
    });

    expect(result.frequencyHz, 36000);
    expect(result.pattern, <int>[
      1778,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      889,
      90886,
    ]);
  });

  test('RC5 keeps existing 6-bit command metadata compatible', () {
    final command = rc5ProtocolDefinition.fields
        .singleWhere((field) => field.id == 'command');
    const encoder = Rc5ProtocolEncoder();
    final existing = encoder.encode(<String, dynamic>{
      'hex': '01A',
      'toggle': false,
    });
    final structured = encoder.encode(<String, dynamic>{
      'address': '00',
      'command': '1A',
      'toggle': false,
    });

    expect(command.max, 0x7F);
    expect(command.label, contains('7 bits'));
    expect(existing.pattern, structured.pattern);
  });
}
