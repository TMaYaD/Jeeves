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

    final refusal = versions.refusal;
    expect(refusal, isNotNull);
    expect(refusal!.storeName, 'domain read model');
    expect(refusal.storedVersion, 12);
    expect(refusal.supportedVersion, GtdDatabase.supportedSchemaVersion);
  });

  test('an op log written by a newer build is refused', () async {
    _writeStoreFile(p.join(directory.path, domainStoreFileName), 11);
    _writeStoreFile(p.join(directory.path, syncStoreFileName), 12);

    final versions = await readLocalStoreVersionsIn(directory.path);

    final refusal = versions.refusal;
    expect(refusal, isNotNull);
    expect(refusal!.storeName, 'op log');
    expect(refusal.storedVersion, 12);
    expect(refusal.supportedVersion, SyncDatabase.supportedSchemaVersion);
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
}
