import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/l10n/app_localizations.dart';
import 'package:swiftremote/widgets/create_button.dart';

/// The create-button screen used to have a Manual | Database switch in its IR
/// signal card. It now shows manual entry directly; this builds the screen,
/// walks to the card and switches between the three signal types, which nothing
/// else in the suite exercises.
void main() {
  testWidgets('the IR signal card shows manual entry with no database switch',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const CreateButton(),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).first, 'VOL+');
    await tester.pump();
    for (int i = 0; i < 2; i++) {
      await tester.tap(find.text('Continue'));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('IR signal'), findsWidgets);
    expect(find.text('Database'), findsNothing);
    expect(find.text('Manual'), findsNothing);
    for (final label in ['Hex (NEC)', 'Raw timings', 'Protocol']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.tap(find.text('Raw timings').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Protocol').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Hex (NEC)').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Enter the signal as a hex code, raw timings or a protocol.'),
        findsOneWidget);
  });
}
