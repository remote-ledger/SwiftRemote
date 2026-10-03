import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/ir/protocols/pioneer.dart';
import 'package:swiftremote/ir_finder/ir_finder_models.dart';
import 'package:swiftremote/ir_finder/irblaster_db.dart';
import 'package:swiftremote/utils/db_button_import.dart';

import 'support/ledger_fixtures.dart';

void main() {
  test('Pioneer database import plays the ledger\'s signal, not the app\'s reading of the hex',
      () async {
    // The app's decoding of a Pioneer database code (address, command and a
    // second address and command) is not the wire's for the data the ledger
    // holds, so a database row carries the ledger's compiled signal instead.
    final dir = await tempCacheDir();
    addTearDown(() => dir.delete(recursive: true));
    final db = IrBlasterDb.forTesting(fixtureLedgerDb(FakeLedgerServer(), dir));
    final rows = await db.fetchCandidateKeys(
      brand: 'AMCREST',
      selectedProtocolId: 'Pioneer',
      quickWinsFirst: true,
      limit: 1 << 30,
    );
    expect(rows, isNotEmpty);

    for (final row in rows) {
      expect(row.requiresSignal, isTrue);
      final button = buildButtonFromDbRow(row);
      expect(button, isNotNull);
      expect(button!.protocol, isNull);
      expect(button.protocolParams, isNull);
      expect(button.rawData, row.signal!.playback()!.rawData);
    }

    // And without the signal there is no button, rather than a decoded one.
    expect(
      buildButtonFromDbRow(const IrDbKeyCandidate(
        id: 1,
        protocol: 'Pioneer',
        hexcode: 'A57AA5E0',
        requiresSignal: true,
      )),
      isNull,
    );
  });

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
