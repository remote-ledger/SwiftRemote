import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/github_store/remote_ledger_index.dart';
import 'package:swiftremote/l10n/app_localizations.dart';
import 'package:swiftremote/widgets/github_store_screen.dart';

const String searchHint = 'Search a device, model or maker, e.g. BDP-S185';

final String indexBody = jsonEncode(<String, Object>{
  'schemaVersion': 1,
  'remotes': <Object>[
    <String, Object>{
      'aliases': <String>[],
      'artifact': 'build/pronto/sony/RMT-B118P.json',
      'confidence': 'plausible',
      'controls': <String>['BDP-S185'],
      'file': 'remotes/sony/RMT-B118P.json',
      'keyCount': 38,
      'manufacturer': 'Sony',
      'model': 'RMT-B118P',
      'protocol': 'Sony20',
      'unresolvedAlternates': 0,
    },
  ],
  'unresolved': <Object>[
    <String, Object>{'checked': '2026-09-24', 'device': 'Sony BDP-BX510'},
  ],
});

void main() {
  late int requests;

  Future<void> openStore(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = 0;
    final service = RemoteLedgerIndexService(
      client: MockClient((request) async {
        requests++;
        return http.Response.bytes(utf8.encode(indexBody), 200);
      }),
      // No cache directory, so the test never waits on real file IO.
      cacheDirectory: () async => throw UnsupportedError('no cache here'),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GitHubStoreScreen(ledgerService: service),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.widgetWithText(TextField, searchHint), query);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the store searches Remote Ledger before anything is loaded',
      (tester) async {
    await openStore(tester);
    expect(requests, 0, reason: 'nothing is fetched until someone searches');

    await search(tester, 'bdp s185');

    expect(find.text('Sony RMT-B118P'), findsOneWidget);
    expect(
      find.text('Controls BDP-S185 · 38 keys · Sony20 · authored'),
      findsOneWidget,
    );
    expect(find.text('1 remote in Remote Ledger'), findsOneWidget);
    expect(requests, 1);
  });

  testWidgets('a device checked and not found says so', (tester) async {
    await openStore(tester);
    await search(tester, 'BX510');

    expect(find.text('Sony BDP-BX510'), findsOneWidget);
    expect(
      find.text('Checked 2026-09-24, and no known remote found.'),
      findsOneWidget,
    );
  });

  testWidgets('a device nobody has looked for is not reported as absent',
      (tester) async {
    await openStore(tester);
    await search(tester, 'KDL-40');

    expect(
      find.textContaining('nobody has recorded looking for it'),
      findsOneWidget,
    );
  });

  testWidgets('clearing the search goes back to the folder view',
      (tester) async {
    await openStore(tester);
    await search(tester, 'bdp s185');
    await search(tester, '');

    expect(find.text('Sony RMT-B118P'), findsNothing);
    expect(find.text('Load Remote Ledger'), findsOneWidget);
  });
}
