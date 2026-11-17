/// The schema-version read at the file level.
///
/// The one part no widget test can reach: what the two store files say about
/// themselves before anything opens them. Asserted over a temp directory
/// rather than the app documents directory, which is why the read takes one.
///
/// The rule the read has to keep: it tells the gate the truth, and it changes
/// nothing. A read that relabelled a file, or that left a store it had read
/// different from how it found it, would be the very damage the gate exists to
/// prevent.
///
/// **And it tells the truth about a file it cannot read.** A file that is there
/// but cannot be opened says nothing about the schema it carries, and that is
/// not the same as there being no file: the gate has to keep both stores
/// closed on it.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/store_schema.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../test_helpers.dart';

/// A store file carrying [version], and nothing else.
void _writeStoreFile(String path, int version) {
  final database = sqlite3.open(path);
  try {
    database.userVersion = version;
  } finally {
    database.close();
  }
}

/// The bytes of the file at [path], or null when there is no file.
List<int>? _bytesOf(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.readAsBytesSync();
}

/// Every row of [table] in the file at [path].
///
/// Read-only, so that reading a fixture does not write to it: a read-write
/// open of a store with an uncheckpointed log folds that log into the store.
List<Map<String, Object?>> _rowsOf(String path, String table) {
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return database.select('SELECT * FROM $table');
  } finally {
    database.close();
  }
}

/// The schema version the file at [path] carries.
int _userVersionOf(String path) {
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return database.userVersion;
  } finally {
    database.close();
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jeeves_store_schema_');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  test('a directory with no stores reports no version for either', () async {
    final versions = await readLocalStoreVersionsIn(directory.path);

    expect(versions.domainStoreVersion, isNull);
    expect(versions.syncStoreVersion, isNull);
    expect(versions.domainStore.isAbsent, isTrue);
    expect(versions.syncStore.isAbsent, isTrue);
    expect(versions.refusal, isNull,
        reason: 'a store the app has yet to create is one it may write');
  });

  test('it reads the version each store file carries', () async {
    _writeStoreFile(p.join(directory.path, domainStoreFileName), 7);
    _writeStoreFile(p.join(directory.path, syncStoreFileName), 9);

    final versions = await readLocalStoreVersionsIn(directory.path);

    expect(versions.domainStoreVersion, 7);
    expect(versions.syncStoreVersion, 9);
    expect(versions.refusal, isNull);
  });

  test('a store written by a newer build is refused', () async {
    _writeStoreFile(p.join(directory.path, domainStoreFileName), 12);
    _writeStoreFile(p.join(directory.path, syncStoreFileName), 11);

    final versions = await readLocalStoreVersionsIn(directory.path);

    final refusal = versions.tooNew;
    expect(refusal, isNotNull);
    expect(refusal!.storeName, 'domain read model');
    expect(refusal.storedVersion, 12);
    expect(refusal.supportedVersion, GtdDatabase.supportedSchemaVersion);
    expect(versions.refusal, isNotNull);
  });

  test('an op log written by a newer build is refused', () async {
    _writeStoreFile(p.join(directory.path, domainStoreFileName), 11);
    _writeStoreFile(p.join(directory.path, syncStoreFileName), 12);

    final versions = await readLocalStoreVersionsIn(directory.path);

    final refusal = versions.tooNew;
    expect(refusal, isNotNull);
    expect(refusal!.storeName, 'op log');
    expect(refusal.storedVersion, 12);
    expect(refusal.supportedVersion, SyncDatabase.supportedSchemaVersion);
    expect(versions.refusal, isNotNull);
  });

  test('the read leaves both files exactly as it found them', () async {
    _writeStoreFile(p.join(directory.path, domainStoreFileName), 12);
    _writeStoreFile(p.join(directory.path, syncStoreFileName), 11);
    final before = {
      for (final name in [domainStoreFileName, syncStoreFileName])
        name: File(p.join(directory.path, name)).readAsBytesSync(),
    };

    await readLocalStoreVersionsIn(directory.path);

    for (final entry in before.entries) {
      expect(
        File(p.join(directory.path, entry.key)).readAsBytesSync(),
        entry.value,
        reason: '${entry.key} must come out of the read exactly as it went in',
      );
    }
  });

  group('a file it cannot read', () {
    test('is not a file that is not there', () async {
      // A file that is not a database at all: it is there, and this build
      // cannot read what it carries.
      File(p.join(directory.path, domainStoreFileName))
          .writeAsStringSync('not a database; a file is a file');

      final versions = await readLocalStoreVersionsIn(directory.path);

      expect(versions.domainStore.isAbsent, isFalse,
          reason: 'the file is there');
      expect(versions.domainStore.isUnreadable, isTrue);
      expect(versions.domainStoreVersion, isNull);
      expect(versions.unreadable, isNotNull);
      expect(versions.unreadable!.storeName, 'domain read model');
      expect(versions.refusal, isNotNull,
          reason: 'an inconclusive check refuses, exactly as a newer file '
              'does');
    });

    test('does not stop the other store from being read', () async {
      File(p.join(directory.path, domainStoreFileName))
          .writeAsStringSync('not a database; a file is a file');
      _writeStoreFile(p.join(directory.path, syncStoreFileName), 9);

      final versions = await readLocalStoreVersionsIn(directory.path);

      expect(versions.domainStore.isUnreadable, isTrue);
      expect(versions.syncStoreVersion, 9,
          reason: 'the file that can be read is still read');
    });

    test('is refused in the other direction too', () async {
      _writeStoreFile(p.join(directory.path, domainStoreFileName), 9);
      File(p.join(directory.path, syncStoreFileName))
          .writeAsStringSync('not a database; a file is a file');

      final versions = await readLocalStoreVersionsIn(directory.path);

      expect(versions.syncStore.isUnreadable, isTrue);
      expect(versions.unreadable!.storeName, 'op log');
      expect(versions.refusal, isNotNull);
    });
  });

  group('a store held under a lock', () {
    test('cannot be read, and the other store still can', () async {
      // A real file, held under an exclusive SQLite lock: SQLite gives the
      // holder the exclusive lock and refuses every other connection, so the
      // read cannot get to the version inside.
      //
      // The fixture is a plain rollback-journal database on purpose: a
      // write-ahead-log file does not block a reader under an exclusive lock,
      // and what this case is about is what the gate does with a file it
      // cannot read.
      final locked = sqlite3.open(p.join(directory.path, syncStoreFileName));
      locked.execute('CREATE TABLE reduced_fields (id TEXT PRIMARY KEY)');
      locked.execute("INSERT INTO reduced_fields VALUES ('r1')");
      locked.execute('BEGIN EXCLUSIVE');
      addTearDown(() {
        locked.execute('ROLLBACK');
        locked.close();
      });
      _writeStoreFile(p.join(directory.path, domainStoreFileName), 9);

      final versions = await readLocalStoreVersionsIn(directory.path);

      expect(versions.syncStore.isUnreadable, isTrue);
      expect(versions.unreadable!.storeName, 'op log');
      expect(versions.domainStoreVersion, 9,
          reason: 'the file that can be read is still read');
      expect(versions.refusal, isNotNull);
    });

    test('cannot be read in the read model either', () async {
      final locked = sqlite3.open(p.join(directory.path, domainStoreFileName));
      locked.execute('CREATE TABLE todos (id TEXT PRIMARY KEY)');
      locked.execute("INSERT INTO todos VALUES ('t1')");
      locked.execute('BEGIN EXCLUSIVE');
      addTearDown(() {
        locked.execute('ROLLBACK');
        locked.close();
      });
      _writeStoreFile(p.join(directory.path, syncStoreFileName), 9);

      final versions = await readLocalStoreVersionsIn(directory.path);

      expect(versions.domainStore.isUnreadable, isTrue);
      expect(versions.unreadable!.storeName, 'domain read model');
      expect(versions.syncStoreVersion, 9);
      expect(versions.refusal, isNotNull);
    });
  });

  group('a store with an uncheckpointed log', () {
    // The state a build leaves behind while it is still running: the rows are
    // in the log beside the store, not in the store yet. The read has to
    // recover that log to learn the version, and it has to leave it be.
    test('keeps its rows, its version and its bytes', () async {
      final path = p.join(directory.path, domainStoreFileName);
      final writer = sqlite3.open(path);
      addTearDown(writer.close);
      writer.execute('PRAGMA journal_mode = WAL');
      writer.execute('CREATE TABLE todos (id TEXT PRIMARY KEY, title TEXT)');
      writer.execute("INSERT INTO todos VALUES ('t1', 'Ring Alice back')");
      writer.userVersion = GtdDatabase.supportedSchemaVersion;

      // The log is beside the store, and it holds what the store does not yet.
      expect(File('$path-wal').existsSync(), isTrue,
          reason: 'the fixture has to have a log for this case to mean '
              'anything');
      final mainBefore = _bytesOf(path);
      final logBefore = _bytesOf('$path-wal');

      final versions = await readLocalStoreVersionsIn(directory.path);

      // **The read recovered the log, so it knows the version inside it.**
      expect(versions.domainStoreVersion, GtdDatabase.supportedSchemaVersion);

      // **And it changed nothing.** The store's own bytes and the log's bytes
      // are the ones it found: no checkpoint moved a row, and no row went
      // anywhere.
      expect(_bytesOf(path), mainBefore,
          reason: 'the store must come out of the read exactly as it went in');
      expect(_bytesOf('$path-wal'), logBefore,
          reason: 'the log must come out of the read exactly as it went in');

      // **Every row is still there, and the version is still the version.**
      final rows = _rowsOf(path, 'todos');
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'Ring Alice back');
      expect(_userVersionOf(path), GtdDatabase.supportedSchemaVersion);
    });

    test('keeps them across repeated reads', () async {
      final path = p.join(directory.path, domainStoreFileName);
      final writer = sqlite3.open(path);
      addTearDown(writer.close);
      writer.execute('PRAGMA journal_mode = WAL');
      writer.execute('CREATE TABLE todos (id TEXT PRIMARY KEY, title TEXT)');
      writer.execute("INSERT INTO todos VALUES ('t1', 'Ring Alice back')");
      writer.userVersion = GtdDatabase.supportedSchemaVersion;
      final mainBefore = _bytesOf(path);
      final logBefore = _bytesOf('$path-wal');

      for (var launch = 0; launch < 3; launch++) {
        final versions = await readLocalStoreVersionsIn(directory.path);
        expect(versions.domainStoreVersion, GtdDatabase.supportedSchemaVersion,
            reason: 'launch $launch');
        expect(versions.refusal, isNull, reason: 'launch $launch');
      }

      expect(_bytesOf(path), mainBefore);
      expect(_bytesOf('$path-wal'), logBefore);
      final rows = _rowsOf(path, 'todos');
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'Ring Alice back');
      expect(_userVersionOf(path), GtdDatabase.supportedSchemaVersion);
    });

    test('is read with no other connection open, and the store is left be',
        () async {
      // The shape a store is in after the app that wrote it was killed: the
      // log is beside the store, and nothing holds it open. This is the case
      // the gate is most likely to meet, because the app that wrote the store
      // is the one that is no longer running.
      final path = p.join(directory.path, domainStoreFileName);
      final writer = sqlite3.open(path);
      addTearDown(writer.close);
      writer.execute('PRAGMA journal_mode = WAL');
      writer.execute('CREATE TABLE todos (id TEXT PRIMARY KEY, title TEXT)');
      writer.execute("INSERT INTO todos VALUES ('t1', 'Ring Alice back')");
      writer.userVersion = GtdDatabase.supportedSchemaVersion;
      expect(File('$path-wal').existsSync(), isTrue,
          reason: 'the fixture has to have a log for this case to mean '
              'anything');

      // A copy of the store and its log, in a directory of its own: no
      // connection is open on the copy, and its shared-memory index is gone
      // with the app that wrote it.
      final copyDirectory = Directory(p.join(directory.path, 'killed'))
        ..createSync(recursive: true);
      final copyPath = p.join(copyDirectory.path, domainStoreFileName);
      File(path).copySync(copyPath);
      File('$path-wal').copySync('$copyPath-wal');

      final mainBefore = _bytesOf(copyPath);
      final logBefore = _bytesOf('$copyPath-wal');

      final versions = await readLocalStoreVersionsIn(copyDirectory.path);

      // **The read found the version that was in the log.**
      expect(versions.domainStoreVersion, GtdDatabase.supportedSchemaVersion);
      expect(versions.refusal, isNull);

      // **And it moved nothing.** The store's bytes and the log's bytes are
      // the ones it found: the read looked at the log where it lay.
      expect(_bytesOf(copyPath), mainBefore,
          reason: 'the store must come out of the read exactly as it went in');
      expect(_bytesOf('$copyPath-wal'), logBefore,
          reason: 'the log must come out of the read exactly as it went in');

      // **Every row is still there, and the version is still the version.**
      final rows = _rowsOf(copyPath, 'todos');
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'Ring Alice back');
      expect(_userVersionOf(copyPath), GtdDatabase.supportedSchemaVersion);
    });
  });
}
