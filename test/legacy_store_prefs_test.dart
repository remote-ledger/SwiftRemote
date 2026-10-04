import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/github_store/legacy_store_prefs.dart';

void main() {
  test('deletes the saved repositories and the GitHub token, and nothing else',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'irblaster.store.lastRepo': '{"owner":"someone","repo":"else"}',
      'irblaster.store.sources': '[]',
      'irblaster.store.githubAuthToken': 'ghp_secret',
      'irblaster.github.cache.dir.index': <String>['k'],
      'theme_mode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();

    final removed = await removeLegacyGitHubStorePrefsOnce(preferences: prefs);

    expect(removed, 3);
    for (final key in kLegacyGitHubStorePrefKeys) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
    expect(prefs.getString('theme_mode'), 'dark');
    expect(
        prefs.getStringList('irblaster.github.cache.dir.index'), <String>['k']);
  });

  test('names the repository, the sources list and the token', () {
    expect(
      kLegacyGitHubStorePrefKeys,
      containsAll(<String>[
        'irblaster.store.lastRepo',
        'irblaster.store.sources',
        'irblaster.store.githubAuthToken',
      ]),
    );
  });

  test('runs once: a token saved later is not touched', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'irblaster.store.githubAuthToken': 'ghp_first',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(await removeLegacyGitHubStorePrefsOnce(preferences: prefs), 1);

    await prefs.setString('irblaster.store.githubAuthToken', 'ghp_second');

    expect(await removeLegacyGitHubStorePrefsOnce(preferences: prefs), 0);
    expect(prefs.getString('irblaster.store.githubAuthToken'), 'ghp_second');
  });

  test('does nothing, quietly, when there is nothing to delete', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    expect(await removeLegacyGitHubStorePrefsOnce(preferences: prefs), 0);
  });
}
