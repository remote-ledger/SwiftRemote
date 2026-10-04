import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/protocols/pioneer.dart';

void main() {
  test('Pioneer emits the optional second command as its second frame', () {
    const encoder = PioneerProtocolEncoder();
    final mixed = encoder.encode(<String, dynamic>{
      'address': 'A5',
      'command': '7A',
      'secondaryAddress': 'A5',
      'secondaryCommand': 'E0',
    });
    final second = encoder.encode(<String, dynamic>{
      'address': 'A5',
      'command': 'E0',
    });

    expect(mixed.pattern.length, second.pattern.length);
    expect(
      mixed.pattern.sublist(mixed.pattern.length ~/ 2),
      second.pattern.sublist(0, second.pattern.length ~/ 2),
    );
  });
}
