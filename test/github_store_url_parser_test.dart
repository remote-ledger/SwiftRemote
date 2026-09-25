import 'package:flutter_test/flutter_test.dart';
import 'package:swiftremote/github_store/url_parser.dart';

void main() {
  test('A tree URL keeps the branch and the folder it points at', () {
    final ref = parseGitHubUrl(
      'https://github.com/Lucaslhm/Flipper-IRDB/tree/main/TVs/Samsung',
    );

    expect(ref, isNotNull);
    expect(ref!.owner, 'Lucaslhm');
    expect(ref.repo, 'Flipper-IRDB');
    expect(ref.branch, 'main');
    expect(ref.path, 'TVs/Samsung');
  });

  test('A blob URL browses the folder that holds the file', () {
    final ref = parseGitHubUrl(
      'https://github.com/Lucaslhm/Flipper-IRDB/blob/main/TVs/Samsung/TV.ir',
    );

    expect(ref, isNotNull);
    expect(ref!.owner, 'Lucaslhm');
    expect(ref.repo, 'Flipper-IRDB');
    expect(ref.branch, 'main');
    expect(ref.path, 'TVs/Samsung');
  });

  test('A raw file URL is unwrapped like a blob URL', () {
    final ref = parseGitHubUrl(
      'https://github.com/Lucaslhm/Flipper-IRDB/raw/master/ACs/Daikin/AC.ir',
    );

    expect(ref, isNotNull);
    expect(ref!.branch, 'master');
    expect(ref.path, 'ACs/Daikin');
  });

  test('A blob URL for a file in the repository root keeps just the branch',
      () {
    final ref = parseGitHubUrl(
      'https://github.com/Lucaslhm/Flipper-IRDB/blob/main/README.md',
    );

    expect(ref, isNotNull);
    expect(ref!.branch, 'main');
    expect(ref.path, '');
  });

  test('A bare repository URL browses the default branch at the root', () {
    const url = 'https://github.com/Lucaslhm/Flipper-IRDB';
    final ref = parseGitHubUrl(url);

    expect(ref, isNotNull);
    expect(ref!.owner, 'Lucaslhm');
    expect(ref.repo, 'Flipper-IRDB');
    expect(ref.branch, '');
    expect(ref.path, '');
    expect(ref.originalUrl, url);
  });

  test('A Pages repository keeps the dots in its name', () {
    // The store's default source, Remote Ledger's compiled remotes.
    final ref = parseGitHubUrl(
      'https://github.com/remote-ledger/remote-ledger.github.io/tree/master/build/pronto',
    );

    expect(ref, isNotNull);
    expect(ref!.owner, 'remote-ledger');
    expect(ref.repo, 'remote-ledger.github.io');
    expect(ref.branch, 'master');
    expect(ref.path, 'build/pronto');
  });

  test('An escaped folder name is decoded for the contents API', () {
    final ref = parseGitHubUrl(
      'https://github.com/Lucaslhm/Flipper-IRDB/tree/main/Audio%20Receivers',
    );

    expect(ref, isNotNull);
    expect(ref!.path, 'Audio Receivers');
  });

  test('URLs that are not GitHub repository links are rejected', () {
    expect(parseGitHubUrl('https://gitlab.com/Lucaslhm/Flipper-IRDB'), isNull);
    expect(
      parseGitHubUrl('https://raw.githubusercontent.com/o/r/main/TV.ir'),
      isNull,
    );
    expect(parseGitHubUrl('https://github.com/Lucaslhm'), isNull);
    expect(parseGitHubUrl('   '), isNull);
    expect(parseGitHubUrl('this is not a link'), isNull);
  });
}
