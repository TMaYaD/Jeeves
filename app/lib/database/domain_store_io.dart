// Native opener for the domain read model's store (Android, iOS, macOS, Linux,
// Windows).
//
// Selected by the conditional export in domain_store.dart when dart:io is
// available. All dart:io and path_provider usage is confined here so the rest of
// the codebase compiles on web.
//
// This file is where the store cutover happens (ADR-0035): it opens a file Drift
// owns outright, reports whether it had to create it, and deletes the
// PowerSync-era store it replaces.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// The domain read model's file. Drift creates and migrates it; nothing else
/// writes it.
const String domainStoreFileName = 'jeeves_domain.sqlite';

/// The PowerSync-era store this replaces, deleted on the first open of the new
/// one.
///
/// Not converted, and not kept: its application-visible names were *views* over
/// PowerSync's internal `ps_data__*` tables, so nothing in it can be read by a
/// Drift-owned schema without the engine that installed the views — and keeping
/// the engine on to read it once is the branching the pivot exists to remove.
/// The local op log, which lives in its own file, is the recovery path.
const String legacyPowerSyncStoreFileName = 'jeeves.sqlite';

/// A freshly opened domain store, and whether this open created it.
///
/// [createdFresh] is what decides whether the op log gets projected in: only a
/// store that did not exist a moment ago is empty enough for a rebuild to be a
/// rebuild rather than a duplicate write.
typedef DomainStoreOpening = ({SqliteDatabase database, bool createdFresh});

class DomainStoreImpl {
  /// Open (creating on first run) the domain store in the app documents
  /// directory.
  Future<DomainStoreOpening> openDatabase() async =>
      openDomainStoreIn((await getApplicationDocumentsDirectory()).path);
}

/// The whole of the open path, over an explicit [directoryPath].
///
/// Split out from [DomainStoreImpl.openDatabase] so the behaviour that matters —
/// fresh-vs-existing detection and the legacy file's disposal — is testable
/// against a temp directory instead of only on a device.
Future<DomainStoreOpening> openDomainStoreIn(String directoryPath) async {
  final file = File(p.join(directoryPath, domainStoreFileName));
  // Before the open, which creates it. `-wal`/`-shm` are irrelevant here: a
  // sidecar without its main file is not a store.
  final createdFresh = !file.existsSync();

  final database = SqliteDatabase(path: file.path);
  await database.initialize();

  deleteLegacyPowerSyncStore(directoryPath);

  return (database: database, createdFresh: createdFresh);
}

/// Delete the PowerSync-era store and its SQLite sidecars.
///
/// Idempotent: absence is a no-op, so it is safe on every launch and there is no
/// "have I done this yet" flag to get wrong. Best-effort per file — a store that
/// could not be deleted is wasted disk, not a broken app, and the next launch
/// tries again.
void deleteLegacyPowerSyncStore(String directoryPath) {
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File(p.join(directoryPath, '$legacyPowerSyncStoreFileName$suffix'));
    if (!file.existsSync()) continue;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Best-effort.
    }
  }
}
