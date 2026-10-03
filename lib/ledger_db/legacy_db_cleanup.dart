import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The IR code database used to be a 51 MB sqlite bundled in the app and
/// copied into the databases directory the first time the Signal Tester was
/// opened. It is read from the Remote Ledger now, and an install that upgrades
/// from one of those builds still has the copy, unused, taking the space.
///
/// These are every file that copy left (the database, the marker beside it,
/// the staging file of an interrupted copy, SQLite's journals) and the name it
/// had before the app was renamed.
const List<String> kLegacyIrDatabaseFiles = <String>[
  'swiftremote.sqlite',
  'swiftremote.sqlite.version',
  'swiftremote.sqlite.new',
  'swiftremote.sqlite-journal',
  'swiftremote.sqlite-wal',
  'swiftremote.sqlite-shm',
  'irblaster.sqlite',
];

const String _doneKey = 'ir_database_legacy_cleanup_v1';

/// Where the old copy can be: Android's `databases` directory sits beside the
/// application support directory (`files`); the Apple platforms kept it in the
/// documents directory.
Future<List<Directory>> legacyIrDatabaseDirectories() async {
  final List<Directory> out = <Directory>[];
  try {
    final Directory support = await getApplicationSupportDirectory();
    out.add(Directory('${support.parent.path}/databases'));
  } catch (_) {}
  try {
    out.add(await getApplicationDocumentsDirectory());
  } catch (_) {}
  return out;
}

/// Deletes what the old bundled database left behind, once. Best effort: a
/// file that cannot be removed is left, and nothing here may stop the app
/// from starting. Returns how many files were deleted.
///
/// Once it has run it records that in the shared preferences and does nothing
/// afterwards.
Future<int> removeLegacyIrDatabaseOnce({
  List<Directory>? directories,
  SharedPreferences? preferences,
}) async {
  try {
    final SharedPreferences prefs =
        preferences ?? await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return 0;

    int removed = 0;
    for (final Directory dir
        in directories ?? await legacyIrDatabaseDirectories()) {
      for (final String name in kLegacyIrDatabaseFiles) {
        try {
          final File file = File('${dir.path}/$name');
          if (await file.exists()) {
            await file.delete();
            removed++;
          }
        } catch (_) {
          // Housekeeping only.
        }
      }
    }
    await prefs.setBool(_doneKey, true);
    return removed;
  } catch (_) {
    return 0;
  }
}
