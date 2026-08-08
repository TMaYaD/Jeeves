/// The open path at the file level (issues #595, #673).
///
/// The one part no widget or DAO test can reach: whether the store is created,
/// whether the open can tell that the op log still owes it a replay, and that
/// the open unlinks nothing. Asserted over a temp directory rather than the app
/// documents directory, which is why the open path takes one —
/// `DomainStoreImpl.openDatabase()` is that call plus `path_provider`.
///
/// The last of those is the one worth stating out loud. The open path used to
/// delete the predecessor name unconditionally; it does not any more, and the
/// case at the bottom is what keeps it that way. The directory this resolves to
/// is app-private on Android but the *user's* own Documents folder on Linux and
/// Windows, so a file the app did not create can sit in it — and deleting by
/// file name alone cannot tell the difference.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';

import '../test_helpers.dart';

/// The name the domain read model used before the cut-over, with the
/// `-wal` and `-shm` sidecars SQLite leaves beside one in WAL mode.
///
/// Spelled out here rather than imported: no production code knows this name any
/// more, and re-introducing a constant for it would be the first step back
/// towards touching it.
List<File> _fabricatePredecessorStore(Directory directory) {
  final files = [
    for (final suffix in const ['', '-wal', '-shm'])
      File('${directory.path}/jeeves.sqlite$suffix'),
  ];
  for (final file in files) {
    // Deliberately *not* a faithful SQLite header: the open path never opens or
    // inspects these bytes, so a fixture that mimicked one would suggest the
    // contents are load-bearing.
    file.writeAsStringSync('not a database; a file is a file');
  }
  return files;
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('jeeves_domain_store_');
  });

  tearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  test('the first open creates the store and owes it a replay', () async {
    final opening = await openDomainStoreIn(directory.path);
    addTearDown(opening.database.close);

    expect(opening.needsRebuild, isTrue);
    expect(File('${directory.path}/$domainStoreFileName').existsSync(), isTrue);
  });

  test('an open after a completed replay does not ask for another', () async {
    final first = await openDomainStoreIn(directory.path);
    first.markRebuilt();
    await first.database.close();

    final second = await openDomainStoreIn(directory.path);
    addTearDown(second.database.close);

    // The marker is what gates the op-log replay: a store that has already been
    // projected into holds the projection, and walking it again is wasted work.
    expect(second.needsRebuild, isFalse);
    expect(
      File('${directory.path}/$domainRebuildMarkerFileName').existsSync(),
      isTrue,
    );
  });

  test('an open after a replay that never completed asks again', () async {
    // The failure mode the marker exists for: the store was created, the replay
    // threw part-way, and the file's existence alone would say "already done"
    // for ever — stranding the log's reduced state in a file nothing reads.
    final first = await openDomainStoreIn(directory.path);
    await first.database.close();

    final second = await openDomainStoreIn(directory.path);
    addTearDown(second.database.close);

    expect(second.needsRebuild, isTrue);
  });

  test('a store deleted out from under a marker is replayed into again',
      () async {
    final first = await openDomainStoreIn(directory.path);
    first.markRebuilt();
    await first.database.close();
    File('${directory.path}/$domainStoreFileName').deleteSync();

    // The marker follows the store rather than outliving it: a create clears it,
    // so a fresh file is never mistaken for one that has been projected into.
    final second = await openDomainStoreIn(directory.path);
    addTearDown(second.database.close);

    expect(second.needsRebuild, isTrue);
  });

  test('the open leaves a file it did not create alone', () async {
    final predecessor = _fabricatePredecessorStore(directory);
    expect(predecessor.every((f) => f.existsSync()), isTrue,
        reason: 'the fixture has to exist for its survival to mean anything');

    final opening = await openDomainStoreIn(directory.path);
    addTearDown(opening.database.close);

    // Green-field: there is no legacy store to migrate, so there is nothing to
    // be gained by unlinking one — and on Linux and Windows this directory is
    // the user's own Documents folder, where a `jeeves.sqlite` need not be ours.
    // The open creates its file and reads its marker; it deletes nothing.
    for (final file in predecessor) {
      expect(file.existsSync(), isTrue, reason: file.path);
    }
    expect(File('${directory.path}/$domainStoreFileName').existsSync(), isTrue);
  });

  test('a re-open beside a file it did not create still succeeds', () async {
    _fabricatePredecessorStore(directory);
    final first = await openDomainStoreIn(directory.path);
    await first.database.close();

    final second = await openDomainStoreIn(directory.path);
    addTearDown(second.database.close);
    expect(File('${directory.path}/$domainStoreFileName').existsSync(), isTrue);
    expect(File('${directory.path}/jeeves.sqlite').existsSync(), isTrue);
  });
}
