import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/utils/db_button_import.dart';
import 'package:swiftremote/utils/ir.dart';
import 'package:swiftremote/utils/remote.dart';

import 'support/ledger_fixtures.dart';

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

  void expectValidSignal(IRButton? button, String reason) {
    expect(button, isNotNull, reason: reason);
    final preview = previewIRButton(button!);
    expect(preview.frequencyHz, greaterThan(0), reason: reason);
    expect(preview.pattern, isNotEmpty, reason: reason);
    expect(
      preview.pattern.every((duration) => duration > 0),
      isTrue,
      reason: reason,
    );
  }

  test(
      'A database code for each protocol the app decodes produces a valid signal',
      () {
    // The protocols whose database codes the app reads as the wire does: its
    // own decoding is right for them, so a row is decoded from its hex.
    const samples = <String, String>{
      'F12_relaxed': 'A84',
      'NEC': '10EFD02F',
      'NEC2': '04FBC837',
      'NECx1': '505050AF',
      'NECx2': 'E0E0C43B',
      'RC5': '81A',
      'RC6': '0000',
      'RCA_38': 'F30',
      'RCC0082': '53C',
      'REC80': 'C2CA80204C90',
      'RECS80': 'AA8',
      'RECS80_L': 'F30',
      'Samsung36': '0400E24',
    };

    for (final entry in samples.entries) {
      final button = buildButtonFromDbRow(IrDbKeyCandidate(
        id: 1,
        protocol: entry.key,
        hexcode: entry.value,
      ));
      expectValidSignal(button, entry.key);
    }
  });

  test(
      'A database code for each of the ten the ledger compiles produces a valid signal',
      () async {
    // Their rows come from the ledger's files, with the compiled signal the
    // app plays (the app's own decoding is wrong for the data here).
    const brands = <String, String>{
      'Denon': 'UNIDEN',
      'JVC': 'VOLVO',
      'Pioneer': 'AMCREST',
      'Proton': 'SATEC',
      'RCC2026': 'JIN LIPU',
      'SONY12': 'BRENNAN',
      'SONY15': 'BRENNAN',
      'SONY20': 'BRENNAN',
      'Sharp': 'STRIM(AMINO)',
      'Thomson7': 'B2B.TEST',
    };

    for (final entry in brands.entries) {
      final rows = await db.fetchCandidateKeys(
        brand: entry.value,
        selectedProtocolId: entry.key,
        quickWinsFirst: true,
        limit: 1 << 30,
      );
      expect(rows, isNotEmpty, reason: entry.key);
      for (final row in rows) {
        expect(row.requiresSignal, isTrue, reason: entry.key);
        final button = buildButtonFromDbRow(row);
        expectValidSignal(button, '${entry.key} ${row.hexcode}');
        // A raw button, not one rebuilt from fields.
        expect(button!.rawData, isNotEmpty, reason: entry.key);
        expect(button.protocol, isNull, reason: entry.key);
      }
    }
  });

  test(
      'A database row of a protocol the app plays from a signal is not decoded '
      'when its signal is missing', () {
    for (final protocol in <String>[
      'Denon', 'JVC', 'Pioneer', 'Proton', 'RCC2026', 'SONY12', 'SONY15',
      'SONY20', 'Sharp', 'Thomson7', //
    ]) {
      final button = buildButtonFromDbRow(IrDbKeyCandidate(
        id: 1,
        protocol: protocol,
        hexcode: '0000',
        requiresSignal: true,
      ));
      expect(button, isNull, reason: protocol);
    }
  });
}
