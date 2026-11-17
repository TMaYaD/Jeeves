// Native reader for the two local stores' schema versions (Android, iOS,
// macOS, Linux, Windows).
//
// Selected by the conditional export in store_schema.dart when dart:io is
// available. All dart:io, path_provider and sqlite3 usage is confined here so
// the rest of the codebase compiles on web.
//
// **The read changes nothing.** It reads `PRAGMA user_version` and closes the
// connection again: no row moves, no schema version moves, and the store's
// own migration path is never entered. What SQLite does on its own — keeping
// the write-ahead log, and checkpointing it into the store — is the engine's
// ordinary recovery, and it moves committed rows rather than dropping them.
//
// **The connection is read-write, and has to be.** The domain store is in
// write-ahead-log mode, and a read-only connection cannot recover a log it
// did not create: on the very files this gate exists to protect — a store left
// behind by a build that is no longer running — the read-only open fails, and
// the gate would report no version at all and let the build walk into the
// store it was meant to refuse.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sync/sync_store.dart';
import 'domain_store.dart';

/// The two store files' schema versions, in the app documents directory.
Future<({int? domainStoreVersion, int? syncStoreVersion})>
    readStoreFileVersions() async {
  final directory = await getApplicationDocumentsDirectory();
  return readStoreFileVersionsIn(directory.path);
}

/// The two store files' schema versions, in [directoryPath].
///
/// The version of a file that is not there is null: there is nothing to
/// refuse, and a store the app has yet to create is one it is free to write.
Future<({int? domainStoreVersion, int? syncStoreVersion})>
    readStoreFileVersionsIn(String directoryPath) async {
  return (
    domainStoreVersion:
        _readUserVersion(p.join(directoryPath, domainStoreFileName)),
    syncStoreVersion:
        _readUserVersion(p.join(directoryPath, syncStoreFileName)),
  );
}

/// The schema version the file at [path] carries, or null when there is no
/// file, or when the file cannot be read as a SQLite database.
int? _readUserVersion(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  // An empty file carries no schema. Opening it would turn it into a database
  // before the app has decided what to do with it.
  if (file.lengthSync() == 0) return null;
  try {
    final database = sqlite3.open(path, mode: OpenMode.readWrite);
    try {
      return database.userVersion;
    } finally {
      database.close();
    }
  } on Object {
    // A file that cannot be opened tells the gate nothing. The store's own
    // migration path reads the version for itself, and refuses what it cannot
    // read.
    return null;
  }
}
