import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/ir_protocol_registry.dart';
import 'package:swiftremote/universal_power/power_params.dart';

void main() {
  test('Universal Power unpacks a 12-bit RC5 database code', () {
    expect(totalHexDigitsForProtocol('rc5'), 3);

    final params = buildParamsForProtocol(
      protocolId: 'rc5',
      codeHex: '054',
    );

    expect(
      params,
      <String, dynamic>{'address': '01', 'command': '54'},
    );
    expect(
      IrProtocolRegistry.encoderFor('rc5').encode(params).pattern,
      isNotEmpty,
    );
  });

  // Sony and Pioneer database codes are not decoded here any more: their
  // rows carry the ledger's compiled signal, which Universal Power plays as it
  // is (test/universal_power_ledger_test.dart). What this file holds is the
  // decoding of the codes the app reads as the wire does, and the field
  // layouts each protocol's encoder takes.

  test('Universal Power keeps the Samsung32 address and command bytes', () {
    expect(totalHexDigitsForProtocol('samsung32'), 4);

    final params = buildParamsForProtocol(
      protocolId: 'samsung32',
      codeHex: 'A57A',
    );

    expect(
      params,
      <String, dynamic>{'address': 'A5', 'command': '7A'},
    );
    expect(
      IrProtocolRegistry.encoderFor('samsung32').encode(params).pattern,
      isNotEmpty,
    );
  });

  test('Universal Power builds encodable parameters for every protocol', () {
    const examples = <String, String>{
      'denon': '1234',
      'f12_relaxed': 'A55',
      'jvc': 'A55A',
      'kaseikyo': '80D003',
      'nec': '00FF48B7',
      'nec2': '00FF48B7',
      'necx1': '00FF48B7',
      'necx2': '00FF48B7',
      'nrc17': '5C61',
      'pioneer': 'A57AA5E0',
      'proton': '1234',
      'rc5': '054',
      'rc6': '800F',
      'rca_38': 'F30',
      'rcc0082': '123',
      'rcc2026': '0087FBC03FC',
      'rec80': '28C600212100',
      'recs80': '123',
      'recs80_l': '123',
      'samsung32': 'A57A',
      'samsung36': '00C0001',
      'sharp': '2024',
      'sony12': 'A90',
      'sony15': '6D35',
      'sony20': 'C1011',
      'thomson7': '300',
      'xsat': '5935',
    };

    for (final entry in examples.entries) {
      final params = buildParamsForProtocol(
        protocolId: entry.key,
        codeHex: entry.value,
      );
      final result = IrProtocolRegistry.encoderFor(entry.key).encode(params);
      expect(result.pattern, isNotEmpty, reason: entry.key);
      expect(
        result.pattern.every((duration) => duration > 0),
        isTrue,
        reason: entry.key,
      );
    }
  });
}
