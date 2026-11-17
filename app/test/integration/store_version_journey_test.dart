/// The journey of a build that meets data written by a newer build.
///
/// The whole rule in one place, over a real pair of stores holding real rows:
/// an older build finds a file a newer build wrote, refuses it, leaves it
/// exactly as it found it, opens neither of the two stores, and tells the user
/// what happened — in plain words, with a version to quote and with nothing
/// on the screen that could throw the data away.
///
/// Both directions are covered: a newer read model and a newer op log each
/// leave the other store alone, because the two files are judged together.
///
/// The store-level refusals are pinned in
/// `database/store_version_refusal_test.dart`, and the read that finds the
/// version in `database/store_schema_io_test.dart`.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/store_schema.dart';
import 'package:jeeves/database/store_version_error.dart';
import 'package:jeeves/main.dart';
import 'package:jeeves/providers/build_version_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/screens/store_too_new/store_too_new_copy.dart';
import 'package:jeeves/screens/store_too_new/store_too_new_screen.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../test_helpers.dart';

const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _userId = 'store-version-user';
const String _versionLabel = 'Version 1.0.0-alpha.1951 (1951)';

/// The two stores, holding one real row each.
Future<void> seedStores(String directoryPath) async {
  final opening = await openDomainStoreIn(directoryPath);
  final domain = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
  try {
    await domain.todoDao.insertOutcome(
      id: _outcomeId,
      title: 'Ring Alice back',
      userId: _userId,
      now: DateTime.utc(2026, 1, 1),
    );
  } finally {
    await domain.close();
    await opening.database.close();
  }

  final sync = SyncDatabase(
      NativeDatabase(File(p.join(directoryPath, syncStoreFileName))));
  try {
    // The first query is what creates the schema.
    await sync.customSelect('SELECT 1').getSingle();
    await sync.into(sync.reducedFields).insert(ReducedFieldsCompanion.insert(
          collection: 'todos',
          entityId: 'e1',
          field: 'title',
          valueJson: '"Ring Alice back"',
        ));
  } finally {
    await sync.close();
  }
}

/// The domain store as a newer build would leave it: a version this build
/// does not know, and a table and a column it does not know.
Future<void> relabelDomainStoreAsANewerBuild(String directoryPath) async {
  final opening = await openDomainStoreIn(directoryPath);
  final domain = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
  try {
    await domain.customStatement(
      'PRAGMA user_version = ${GtdDatabase.supportedSchemaVersion + 1}',
    );
    await domain.customStatement(
      'CREATE TABLE future_only (id TEXT PRIMARY KEY, note TEXT)',
    );
    await domain.customStatement(
      'ALTER TABLE todos ADD COLUMN future_column TEXT',
    );
  } finally {
    await domain.close();
    await opening.database.close();
  }
}

/// The op log as a newer build would leave it: a version this build does not
/// know, and a table it does not know.
Future<void> relabelSyncStoreAsANewerBuild(String directoryPath) async {
  final sync = SyncDatabase(
      NativeDatabase(File(p.join(directoryPath, syncStoreFileName))));
  try {
    await sync.customStatement(
      'PRAGMA user_version = ${SyncDatabase.supportedSchemaVersion + 1}',
    );
    await sync.customStatement(
      'CREATE TABLE future_only (id TEXT PRIMARY KEY, note TEXT)',
    );
  } finally {
    await sync.close();
  }
}

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

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jeeves_store_journey_');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  testWidgets(
      'a build that meets a newer build\'s data refuses it, changes nothing '
      'and says so', (tester) async {
    // **The store work runs in a real-async turn.** A file-backed store is
    // opened through an isolate, and an isolate never answers inside the fake
    // clock a widget test runs on: the wait would never end, and no timeout
    // would fire (docs/TESTING.md).
    await tester.runAsync(() async {
      await seedStores(directory.path);
      await relabelDomainStoreAsANewerBuild(directory.path);
    });
    final domainFile = p.join(directory.path, domainStoreFileName);
    final syncFile = p.join(directory.path, syncStoreFileName);
    final marker = File(p.join(directory.path, domainRebuildMarkerFileName));

    // **The gate reads the two files before anything opens them.**
    final versions = (await tester.runAsync(
      () => readLocalStoreVersionsIn(directory.path),
    ))!;
    expect(versions.refusal, isNotNull);
    expect(versions.refusal!.storeName, 'domain read model');
    expect(versions.refusal!.storedVersion,
        GtdDatabase.supportedSchemaVersion + 1);

    // **Neither store is opened.** The op log is refused too: a build that
    // cannot read the read model would project reduced state into it.
    await tester.runAsync(() async {
      final container = ProviderContainer(overrides: [
        localStoreVersionsProvider.overrideWith((ref) async => versions),
      ]);
      addTearDown(container.dispose);
      await expectLater(
        container.read(domainStoreProvider.future),
        throwsA(isA<StoreVersionTooNewError>()),
        reason: 'the read model is not opened',
      );
      await expectLater(
        container.read(syncDatabaseProvider.future),
        throwsA(isA<StoreVersionTooNewError>()),
        reason: 'the op log is not opened either',
      );
    });

    // **The app says what happened.**
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          buildVersionLabelProvider.overrideWith((ref) async => _versionLabel),
        ],
        child: JeevesApp(storeVersions: versions),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StoreTooNewScreen), findsOneWidget);
    expect(find.text(storeTooNewTitle), findsOneWidget);
    expect(find.text(storeTooNewExplanation), findsOneWidget);
    expect(find.text(storeTooNewAdvice), findsOneWidget);
    expect(find.text('Running version: $_versionLabel'), findsOneWidget);

    // **Nothing on the screen can throw the data away.**
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);

    // **Both files are exactly as the newer build left them.**
    await tester.runAsync(() async {
      expect(_userVersionOf(domainFile),
          GtdDatabase.supportedSchemaVersion + 1);
      expect(_rowsOf(domainFile, 'todos'), hasLength(1));
      expect(_rowsOf(domainFile, 'todos').first['title'], 'Ring Alice back');
      expect(_rowsOf(domainFile, 'future_only'), hasLength(0),
          reason: "the newer build's table is still empty, and still there");
      expect(_userVersionOf(syncFile), SyncDatabase.supportedSchemaVersion);
      expect(_rowsOf(syncFile, 'reduced_fields'), hasLength(1));
      expect(marker.existsSync(), isFalse,
          reason: 'no replay ran, so there is no marker of a finished replay');
    });
  });

  test('when only the op log is newer, the read model is left alone too',
      () async {
    await seedStores(directory.path);
    await relabelSyncStoreAsANewerBuild(directory.path);
    final domainFile = p.join(directory.path, domainStoreFileName);
    final marker = File(p.join(directory.path, domainRebuildMarkerFileName));

    // **The gate judges the two files together.** The op log is the one that
    // is too new.
    final versions = await readLocalStoreVersionsIn(directory.path);
    expect(versions.refusal, isNotNull);
    expect(versions.refusal!.storeName, 'op log');
    expect(versions.refusal!.storedVersion,
        SyncDatabase.supportedSchemaVersion + 1);

    // **The read model this build could read is not opened either.** A build
    // that cannot read the op log must not project into a read model it would
    // then have to reconcile against a log it does not understand.
    final container = ProviderContainer(overrides: [
      localStoreVersionsProvider.overrideWith((ref) async => versions),
    ]);
    addTearDown(container.dispose);
    await expectLater(
      container.read(domainStoreProvider.future),
      throwsA(isA<StoreVersionTooNewError>()),
      reason: 'the read model is not opened either',
    );
    await expectLater(
      container.read(syncDatabaseProvider.future),
      throwsA(isA<StoreVersionTooNewError>()),
      reason: 'the op log is not opened',
    );

    // **No replay ran, and the read model is exactly as it was.**
    expect(marker.existsSync(), isFalse,
        reason: 'a replay into the read model would have written the marker');
    expect(_userVersionOf(domainFile), GtdDatabase.supportedSchemaVersion);
    expect(_rowsOf(domainFile, 'todos'), hasLength(1));
    expect(_rowsOf(domainFile, 'todos').first['title'], 'Ring Alice back');
  });

  // A plain test, not a widget test: this one is nothing but file work, and
  // the store is opened through an isolate, which a widget test's fake clock
  // would never answer.
  test('a build that understands the store opens it with every row', () async {
    await seedStores(directory.path);
    await relabelDomainStoreAsANewerBuild(directory.path);
    final domainFile = p.join(directory.path, domainStoreFileName);
    // Put the newer build back on the device: the file carries a version this
    // build understands again.
    final relabel = sqlite3.open(domainFile);
    try {
      relabel.userVersion = GtdDatabase.supportedSchemaVersion;
    } finally {
      relabel.close();
    }

    // The gate lets this build through.
    final versions = await readLocalStoreVersionsIn(directory.path);
    expect(versions.refusal, isNull);

    // And the store opens, with the row still in it.
    final opening = await openDomainStoreIn(directory.path);
    final domain = GtdDatabase(SqliteAsyncDriftConnection(opening.database));
    try {
      await domain.customSelect('SELECT 1').getSingle();
      final rows = await domain.select(domain.todos).get();
      expect(rows.map((row) => row.id), contains(_outcomeId));
      expect(
        rows.firstWhere((row) => row.id == _outcomeId).title,
        'Ring Alice back',
      );
    } finally {
      await domain.close();
      await opening.database.close();
    }
  });
}
