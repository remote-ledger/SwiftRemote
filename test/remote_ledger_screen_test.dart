import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/github_store/github_store_service.dart';
import 'package:swiftremote/github_store/remote_ledger_index.dart';
import 'package:swiftremote/l10n/app_localizations.dart';
import 'package:swiftremote/widgets/remote_ledger_screen.dart';

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

/// What the contents API answers for each folder the tests open.
const String _contents =
    '/repos/remote-ledger/remote-ledger.github.io/contents';
final Map<String, List<Object>> folders = <String, List<Object>>{
  '$_contents/build/pronto': <Object>[
    <String, Object>{
      'type': 'dir',
      'name': 'sony',
      'path': 'build/pronto/sony',
    },
  ],
  '$_contents/build/pronto/sony': <Object>[
    <String, Object>{
      'type': 'file',
      'name': 'RMT-B118P.json',
      'path': 'build/pronto/sony/RMT-B118P.json',
    },
  ],
};

void main() {
  late int requests;

  /// Every request the folder browser sends to GitHub, as path and query.
  late List<String> githubRequests;

  Future<void> openStore(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = 0;
    githubRequests = <String>[];
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
        home: RemoteLedgerScreen(
          ledgerService: service,
          storeService: GitHubStoreService(
            client: MockClient((request) async {
              githubRequests.add(request.url.toString());
              return http.Response(
                jsonEncode(folders[request.url.path] ?? <Object>[]),
                200,
              );
            }),
          ),
        ),
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

  testWidgets('there is nowhere to choose another source', (tester) async {
    await openStore(tester);

    // The search box is the only field: no URL to type, no token to paste.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('GitHub URL'), findsNothing);
    expect(find.text('Save source'), findsNothing);
    for (final tooltip in <String>[
      'Saved sources',
      'Pick saved source',
      'Manage sources',
      'GitHub connection',
    ]) {
      expect(find.byTooltip(tooltip), findsNothing, reason: tooltip);
    }
    expect(find.text('remote-ledger/remote-ledger.github.io'), findsOneWidget);
  });

  testWidgets(
      'browsing opens a folder and Up comes back, in Remote Ledger only',
      (tester) async {
    await openStore(tester);
    expect(find.byTooltip('Refresh'), findsOneWidget);

    await tester.tap(find.text('Load Remote Ledger'));
    await tester.pump();
    await tester.pump();
    expect(find.text('sony'), findsOneWidget);
    expect(find.text('/build/pronto'), findsOneWidget);

    await tester.tap(find.text('sony'));
    await tester.pump();
    await tester.pump();
    expect(find.text('RMT-B118P.json'), findsOneWidget);
    expect(find.text('/build/pronto/sony'), findsOneWidget);

    await tester.tap(find.text('Up'));
    await tester.pump();
    await tester.pump();
    expect(find.text('sony'), findsOneWidget);
    expect(find.text('/build/pronto'), findsOneWidget);

    // Up from the folder it opens on goes nowhere.
    expect(
      tester.widget<TextButton>(find.bySubtype<TextButton>()).onPressed,
      isNull,
    );

    for (final url in githubRequests) {
      final uri = Uri.parse(url);
      expect(uri.host, 'api.github.com', reason: url);
      expect(
        uri.path,
        startsWith('$_contents/build/pronto'),
        reason: url,
      );
      expect(uri.queryParameters, <String, String>{'ref': 'master'});
    }
  });
}
