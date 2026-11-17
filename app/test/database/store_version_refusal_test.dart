/// A store written by a newer build is refused, and left exactly as it was.
///
/// The rule at the store level: an older build that opens a file a newer build
/// wrote must change nothing in it. Not the schema version, not a row, not a
/// table — and it must keep refusing on every later launch, so the file never
/// drifts towards a version this build understands.
///
/// The fixture is a real file-backed store holding a real row, relabelled with
/// a version this build does not know and given a table and a column it does
/// not know, which is what a newer build's file looks like from here.
///
/// The journey over the same fixture — the gate, the providers and the screen
/// the user sees — is `integration/store_version_journey_test.dart`.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/store_version_error.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../test_helpers.dart';

const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _userId = 'store-version-user';

/// The version a newer build would leave behind: one above this build's.
int get _newerVersion => GtdDatabase.supportedSchemaVersion + 1;

/// The schema version the file at [path] carries.
///
/// The connection is read-write, and has to be: the domain store is in
/// write-ahead-log mode, and a read-only connection cannot open a log-mode
/// store that has no log beside it — which is exactly the state a store left
/// behind by a build that is no longer running is in.
int _userVersionOf(String path) {
  final database = sqlite3.open(path, mode: OpenMode.readWrite);
  try {
    return database.userVersion;
  } finally {
    database.close();
  }
}

/// Every row of [table] in the file at [path].
List<Map<String, Object?>> _rowsOf(String path, String table) {
  final database = sqlite3.open(path, mode: OpenMode.readWrite);
  try {
    return database.select('SELECT * FROM $table');
  } finally {
    database.close();
  }
}

/// The domain store in [directoryPath], as a newer build would leave it: one
/// real Outcome, a version this build does not know, and a table and a column
/// it does not know.
Future<void> seedDomainStoreFromANewerBuild(String directoryPath) async {
  final opening = await openDomainStoreIn(directoryPath);
  final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
  try {
    await db.todoDao.insertOutcome(
      id: _outcomeId,
      title: 'Ring Alice back',
      userId: _userId,
      now: DateTime.utc(2026, 1, 1),
    );
    await db.customStatement('PRAGMA user_version = $_newerVersion');
    await db.customStatement(
      'CREATE TABLE future_only (id TEXT PRIMARY KEY, note TEXT)',
    );
    await db.customStatement(
      "INSERT INTO future_only (id, note) VALUES ('f1', 'from a newer build')",
    );
    await db.customStatement('ALTER TABLE todos ADD COLUMN future_column TEXT');
  } finally {
    await db.close();
    await opening.database.close();
  }
}

/// The op log in [directoryPath], as a newer build would leave it: one reduced
/// field, a version this build does not know, and a table it does not know.
Future<void> seedSyncStoreFromANewerBuild(String directoryPath) async {
  final file = File(p.join(directoryPath, syncStoreFileName));
  final db = SyncDatabase(NativeDatabase(file));
  try {
    // The first query is what creates the schema.
    await db.customSelect('SELECT 1').getSingle();
    await db.into(db.reducedFields).insert(ReducedFieldsCompanion.insert(
          collection: 'todos',
          entityId: 'e1',
          field: 'title',
          valueJson: '"Ring Alice back"',
        ));
    await db.customStatement(
      'PRAGMA user_version = ${SyncDatabase.supportedSchemaVersion + 1}',
    );
    await db.customStatement(
      'CREATE TABLE future_only (id TEXT PRIMARY KEY, note TEXT)',
    );
    await db.customStatement(
      "INSERT INTO future_only (id, note) VALUES ('f1', 'from a newer build')",
    );
  } finally {
    await db.close();
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jeeves_store_version_');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  group('the domain read model', () {
    test('a store written by a newer build is refused', () async {
      await seedDomainStoreFromANewerBuild(directory.path);

      final opening = await openDomainStoreIn(directory.path);
      final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
      try {
        await expectLater(
          db.customSelect('SELECT 1').getSingle(),
          throwsA(isA<StoreVersionTooNewError>()
              .having((error) => error.storeName, 'storeName',
                  'domain read model')
              .having((error) => error.storedVersion, 'storedVersion',
                  _newerVersion)
              .having((error) => error.supportedVersion, 'supportedVersion',
                  GtdDatabase.supportedSchemaVersion)),
        );
      } finally {
        await db.close();
        await opening.database.close();
      }
    });

    test('the refused store keeps its version, its rows and its tables',
        () async {
      await seedDomainStoreFromANewerBuild(directory.path);
      final file = p.join(directory.path, domainStoreFileName);

      final opening = await openDomainStoreIn(directory.path);
      final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
      try {
        await expectLater(
          db.customSelect('SELECT 1').getSingle(),
          throwsA(isA<StoreVersionTooNewError>()),
        );
      } finally {
        await db.close();
        await opening.database.close();
      }

      expect(_userVersionOf(file), _newerVersion,
          reason: 'the version is not relabelled with one this build knows');
      expect(_rowsOf(file, 'todos'), hasLength(1));
      expect(_rowsOf(file, 'todos').first['title'], 'Ring Alice back');
      expect(_rowsOf(file, 'future_only'), hasLength(1),
          reason: "the newer build's table is still there");
    });

    test('the refusal is the same on every later launch', () async {
      await seedDomainStoreFromANewerBuild(directory.path);

      for (var launch = 0; launch < 3; launch++) {
        final opening = await openDomainStoreIn(directory.path);
        final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
        try {
          await expectLater(
            db.customSelect('SELECT 1').getSingle(),
            throwsA(isA<StoreVersionTooNewError>()),
            reason: 'launch $launch',
          );
        } finally {
          await db.close();
          await opening.database.close();
        }
      }

      expect(_userVersionOf(p.join(directory.path, domainStoreFileName)),
          _newerVersion);
    });

    test('a store this build understands opens with every row intact',
        () async {
      await seedDomainStoreFromANewerBuild(directory.path);
      final file = p.join(directory.path, domainStoreFileName);
      // Put the file back to the version this build understands, the way
      // putting the newer build back on the device would.
      final relabel = sqlite3.open(file);
      try {
        relabel.userVersion = GtdDatabase.supportedSchemaVersion;
      } finally {
        relabel.close();
      }

      final opening = await openDomainStoreIn(directory.path);
      final db = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
      try {
        await db.customSelect('SELECT 1').getSingle();
        final rows = await db.select(db.todos).get();
        expect(rows.map((row) => row.id), contains(_outcomeId));
        expect(rows.firstWhere((row) => row.id == _outcomeId).title,
            'Ring Alice back');
      } finally {
        await db.close();
        await opening.database.close();
      }
    });
  });

  group('the op log', () {
    test('a store written by a newer build is refused', () async {
      await seedSyncStoreFromANewerBuild(directory.path);

      final db = SyncDatabase(
        NativeDatabase(File(p.join(directory.path, syncStoreFileName))),
      );
      try {
        await expectLater(
          db.customSelect('SELECT 1').getSingle(),
          throwsA(isA<StoreVersionTooNewError>()
              .having((error) => error.storeName, 'storeName', 'op log')
              .having((error) => error.storedVersion, 'storedVersion',
                  SyncDatabase.supportedSchemaVersion + 1)
              .having((error) => error.supportedVersion, 'supportedVersion',
                  SyncDatabase.supportedSchemaVersion)),
        );
      } finally {
        await db.close();
      }
    });

    test('the refused store keeps its version and its rows', () async {
      await seedSyncStoreFromANewerBuild(directory.path);
      final file = p.join(directory.path, syncStoreFileName);

      final db = SyncDatabase(NativeDatabase(File(file)));
      try {
        await expectLater(
          db.customSelect('SELECT 1').getSingle(),
          throwsA(isA<StoreVersionTooNewError>()),
        );
      } finally {
        await db.close();
      }

      expect(_userVersionOf(file), SyncDatabase.supportedSchemaVersion + 1);
      expect(_rowsOf(file, 'reduced_fields'), hasLength(1));
      expect(_rowsOf(file, 'reduced_fields').first['valueJson'],
          '"Ring Alice back"');
      expect(_rowsOf(file, 'future_only'), hasLength(1));
    });

    test('a store this build understands opens with every row intact',
        () async {
      await seedSyncStoreFromANewerBuild(directory.path);
      final file = p.join(directory.path, syncStoreFileName);
      final relabel = sqlite3.open(file);
      try {
        relabel.userVersion = SyncDatabase.supportedSchemaVersion;
      } finally {
        relabel.close();
      }

      final db = SyncDatabase(NativeDatabase(File(file)));
      try {
        await db.customSelect('SELECT 1').getSingle();
        final rows = await db.select(db.reducedFields).get();
        expect(rows, hasLength(1));
        expect(rows.first.valueJson, '"Ring Alice back"');
      } finally {
        await db.close();
      }
    });
  });
}
