import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/l10n/app_localizations.dart';
import 'package:swiftremote/state/remotes_state.dart';
import 'package:swiftremote/widgets/remote_ledger_screen.dart';
import 'package:swiftremote/widgets/remote_list.dart';
import 'package:swiftremote/widgets/remote_setup_screen.dart';
import 'package:swiftremote/widgets/remote_studio_screen.dart';

void main() {
  Future<void> openList(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    remotes = [];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const RemoteList(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Add remote opens the search first, not the name and layout page',
      (tester) async {
    await openList(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteLedgerScreen), findsOneWidget);
    expect(find.byType(RemoteSetupScreen), findsNothing);
    expect(find.text('Import a remote'), findsOneWidget);
  });

  testWidgets('the empty state button starts the same way', (tester) async {
    await openList(tester);

    // The floating button is not a FilledButton; this one is the empty state's.
    await tester.tap(find.descendant(
      of: find.bySubtype<FilledButton>(),
      matching: find.text('Add remote'),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteLedgerScreen), findsOneWidget);
    expect(find.byType(RemoteSetupScreen), findsNothing);
  });

  testWidgets('backing out of the search adds nothing and asks nothing',
      (tester) async {
    await openList(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(RemoteList), findsOneWidget);
    expect(find.byType(RemoteSetupScreen), findsNothing);
    expect(find.byType(RemoteStudioScreen), findsNothing);
  });

  testWidgets('Create remote goes on to the name and layout page, then the editor',
      (tester) async {
    await openList(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create remote'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSetupScreen), findsOneWidget);
    expect(find.byType(RemoteLedgerScreen), findsNothing);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteStudioScreen), findsOneWidget);
  });
}
