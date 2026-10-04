import 'package:shared_preferences/shared_preferences.dart';

/// The GitHub Store used to let people pick any GitHub repository. It
/// remembered the last one opened, a list of saved sources, and an optional
/// personal access token. The app reads Remote Ledger only now and has no
/// screen that shows or removes any of these, so an install that upgrades from
/// one of those builds would keep a token it can no longer see.
const List<String> kLegacyGitHubStorePrefKeys = <String>[
  'irblaster.store.lastRepo',
  'irblaster.store.sources',
  'irblaster.store.githubAuthToken',
];

const String _doneKey = 'github_store_legacy_prefs_cleanup_v1';

/// Deletes what the old store left in the shared preferences, once. Best
/// effort: nothing here may stop the app from starting. Returns how many
/// entries were deleted.
///
/// Once it has run it records that and does nothing afterwards.
Future<int> removeLegacyGitHubStorePrefsOnce({
  SharedPreferences? preferences,
}) async {
  try {
    final SharedPreferences prefs =
        preferences ?? await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return 0;

    int removed = 0;
    for (final String key in kLegacyGitHubStorePrefKeys) {
      if (prefs.containsKey(key) && await prefs.remove(key)) removed++;
    }
    await prefs.setBool(_doneKey, true);
    return removed;
  } catch (_) {
    return 0;
  }
}
