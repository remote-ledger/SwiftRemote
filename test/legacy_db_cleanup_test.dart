import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swiftremote/ledger_db/legacy_db_cleanup.dart';

void main() {
  late Directory databases;
  late Directory other;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    databases = await Directory.systemTemp.createTemp('legacy_db_');
    other = await Directory.systemTemp.createTemp('legacy_docs_');
  });

  tearDown(() async {
    for (final Directory d in <Directory>[databases, other]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  void touch(Directory d, String name) =>
      File('${d.path}/$name').writeAsStringSync('x');

  test('deletes every file the bundled database left, and nothing else',
      () async {
    for (final String name in kLegacyIrDatabaseFiles) {
      touch(databases, name);
    }
    touch(databases, 'some_other_app.db');
    touch(other, 'ir_finder_hits.json');

    final int removed = await removeLegacyIrDatabaseOnce(
      directories: <Directory>[databases, other],
    );

    expect(removed, kLegacyIrDatabaseFiles.length);
    expect(
      databases
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .toList(),
      <String>['some_other_app.db'],
    );
    expect(File('${other.path}/ir_finder_hits.json').existsSync(), isTrue);
  });

  test(
      'names the database, its marker, the staging copy and SQLite\'s journals',
      () {
    expect(
        kLegacyIrDatabaseFiles,
        containsAll(<String>[
          'swiftremote.sqlite',
          'swiftremote.sqlite.version',
          'swiftremote.sqlite.new',
          'swiftremote.sqlite-journal',
          'swiftremote.sqlite-wal',
          'swiftremote.sqlite-shm',
          'irblaster.sqlite',
        ]));
  });

  test('runs once: later it looks at nothing', () async {
    touch(databases, 'swiftremote.sqlite');
    expect(
      await removeLegacyIrDatabaseOnce(directories: <Directory>[databases]),
      1,
    );

    touch(databases, 'swiftremote.sqlite');
    expect(
      await removeLegacyIrDatabaseOnce(directories: <Directory>[databases]),
      0,
    );
    expect(File('${databases.path}/swiftremote.sqlite').existsSync(), isTrue);
  });

  test(
      'does nothing, quietly, when there is nothing to delete or no such directory',
      () async {
    final Directory gone = Directory('${databases.path}/nope');

    expect(
      await removeLegacyIrDatabaseOnce(
          directories: <Directory>[gone, databases]),
      0,
    );
  });
}
