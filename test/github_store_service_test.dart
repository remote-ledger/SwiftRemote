import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/github_store/github_store_service.dart';
import 'package:swiftremote/github_store/models.dart';

void main() {
  late List<http.Request> sent;

  GitHubStoreService serviceReplying(
    http.Response Function(http.Request request) reply,
  ) {
    sent = <http.Request>[];
    return GitHubStoreService(
      client: MockClient((request) async {
        sent.add(request);
        return reply(request);
      }),
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('the source is Remote Ledger and is written in one place', () {
    expect(kRemoteLedgerOwner, 'remote-ledger');
    expect(kRemoteLedgerRepo, 'remote-ledger.github.io');
    expect(kRemoteLedgerBranch, 'master');
    expect(kRemoteLedgerBrowseRoot, 'build/pronto');
  });

  test('a folder is listed from the ledger repository, folders first',
      () async {
    final service = serviceReplying(
      (request) => http.Response(
        jsonEncode(<Object>[
          <String, Object>{
            'type': 'file',
            'name': 'a.json',
            'path': 'build/pronto/a.json',
          },
          <String, Object>{
            'type': 'dir',
            'name': 'sony',
            'path': 'build/pronto/sony',
          },
          <String, Object>{
            'type': 'file',
            'name': '.gitkeep',
            'path': 'build/pronto/.gitkeep',
          },
        ]),
        200,
      ),
    );

    final items = await service.listDirectory('build/pronto');

    expect(items.map((item) => item.name), <String>['sony', 'a.json']);
    expect(items.first.type, RepoItemType.dir);
    expect(sent, hasLength(1));
    expect(sent.single.url.host, 'api.github.com');
    expect(
      sent.single.url.path,
      '/repos/remote-ledger/remote-ledger.github.io/contents/build/pronto',
    );
    expect(sent.single.url.queryParameters, <String, String>{'ref': 'master'});
  });

  test('a file is read from the same repository and decoded', () async {
    const text = '{"keys": []}';
    final service = serviceReplying(
      (request) => http.Response(
        jsonEncode(<String, Object>{
          'name': 'RMT-B118P.json',
          'size': text.length,
          'encoding': 'base64',
          'content': base64.encode(utf8.encode(text)),
        }),
        200,
      ),
    );

    final file =
        await service.fetchFileText('build/pronto/sony/RMT-B118P.json');

    expect(file.text, text);
    expect(file.path, 'build/pronto/sony/RMT-B118P.json');
    expect(
      sent.single.url.path,
      '/repos/remote-ledger/remote-ledger.github.io/contents/'
      'build/pronto/sony/RMT-B118P.json',
    );
  });

  test('no request carries credentials, even if an old token is still stored',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'irblaster.store.githubAuthToken': 'ghp_leftover',
    });
    final service = serviceReplying(
      (request) => http.Response(jsonEncode(<Object>[]), 200),
    );

    await service.listDirectory('build/pronto');

    expect(sent.single.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')));
  });

  test('a rate limit says when it lifts', () async {
    final service = serviceReplying(
      (request) => http.Response(
        '{}',
        403,
        headers: <String, String>{'x-ratelimit-reset': '1790000000'},
      ),
    );

    await expectLater(
      service.listDirectory('build/pronto'),
      throwsA(
        isA<GitHubRateLimitException>().having(
          (error) => error.resetAt,
          'resetAt',
          DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000, isUtc: true),
        ),
      ),
    );
  });

  test('a folder is answered from the copy on the device the second time',
      () async {
    final service = serviceReplying(
      (request) => http.Response(jsonEncode(<Object>[]), 200),
    );
    await service.listDirectory('build/pronto');

    final again = GitHubStoreService(
      client: MockClient((request) async {
        fail('a fresh copy should not go back to GitHub');
      }),
    );
    expect(await again.listDirectory('build/pronto'), isEmpty);
  });
}
