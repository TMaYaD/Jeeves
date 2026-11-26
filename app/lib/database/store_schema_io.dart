// Native reader for the two local stores' schema versions (Android, iOS,
// macOS, Linux, Windows).
//
// Selected by the conditional export in store_schema.dart when dart:io is
// available. All dart:io, path_provider and sqlite3 usage is confined here so
// the rest of the codebase compiles on web.
//
// **The read changes nothing.** It reads `PRAGMA user_version` and closes the
// connection again: no row moves, no schema version moves, and the store's
// own migration path is never entered.
//
// **It opens the store read-only wherever SQLite can.** The domain store is in
// write-ahead-log mode, and a read-write open of a store whose log is not
// checkpointed recovers that log and folds it into the store when it closes.
// That moves bytes rather than rows — SQLite's recovery moves committed rows
// and drops none — but it is still a write to a store this build may have
// promised not to touch. A read-only open changes nothing: it reads the log
// where it lies and leaves it there.
//
// **The read-write open is the fallback, and it has to be.** A read-only open
// needs the shared-memory index, and it cannot rebuild one that is missing —
// which is the state a store is in after the app that wrote it was killed. The
// fallback recovers what the read-only open could not, and it fails the same
// way when the store is locked: a locked store is a store this build cannot
// read, and a store it cannot read is a store it must not open.
//
// **A file it cannot open is not a file that is not there.** The read reports
// the difference, so the gate can refuse on it: a file it cannot read may be
// a store a newer build wrote, and this build would not know.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sync/sync_store.dart';
import 'domain_store.dart';
import 'store_file_probe.dart';

/// The two store files' probes, in the app documents directory.
Future<({StoreFileProbe domainStore, StoreFileProbe syncStore})>
    readStoreFileProbes() async {
  final directory = await getApplicationDocumentsDirectory();
  return readStoreFileProbesIn(directory.path);
}

/// The two store files' probes, in [directoryPath].
///
/// The version of a file that is not there is no version at all: there is
/// nothing to refuse, and a store the app has yet to create is one it is free
/// to write. A file that is there but cannot be read is a probe of its own,
/// and the gate refuses on it.
Future<({StoreFileProbe domainStore, StoreFileProbe syncStore})>
    readStoreFileProbesIn(String directoryPath) async {
  return (
    domainStore:
        _probeUserVersion(p.join(directoryPath, domainStoreFileName)),
    syncStore:
        _probeUserVersion(p.join(directoryPath, syncStoreFileName)),
  );
}

/// What the file at [path] carries, or why it could not be read.
///
/// An empty file carries no schema: opening it would turn it into a database
/// before the app has decided what to do with it.
StoreFileProbe _probeUserVersion(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return const StoreFileProbe.absent();
    if (file.lengthSync() == 0) return const StoreFileProbe.absent();
    return StoreFileProbe.readable(_readUserVersion(path));
  } on Object catch (error) {
    // The file is there, and this build cannot read it. That is not the same
    // as there being no file: the gate has to keep both stores closed.
    return StoreFileProbe.unreadable('$error');
  }
}

/// The schema version the file at [path] carries.
///
/// **It reads the store; it does not write to it.** The read-only open is the
/// one that keeps the promise: it reads the write-ahead log where it lies and
/// leaves it there, so not a byte of the store moves.
///
/// The read-write open is the fallback, for the stores a read-only connection
/// cannot reach — a store whose shared-memory index is missing, which is what
/// a store is after the app that wrote it was killed. Recovering the log there
/// is the only way to learn what the store carries, and SQLite's recovery
/// moves committed rows rather than dropping them.
int _readUserVersion(String path) {
  try {
    final database = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return database.userVersion;
    } finally {
      database.close();
    }
  } on Object {
    final database = sqlite3.open(path, mode: OpenMode.readWrite);
    try {
      return database.userVersion;
    } finally {
      database.close();
    }
  }
}
