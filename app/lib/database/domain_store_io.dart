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

/// The marker that records a *completed* op-log replay into the domain store.
///
/// Its own file rather than a row, because it has to be readable before the
/// store is open and survive a replay that threw halfway through one.
const String domainRebuildMarkerFileName = 'jeeves_domain.rebuilt';

/// A freshly opened domain store, whether the op log still owes it a replay, and
/// the way to record that the replay finished.
///
/// [needsRebuild] is what decides whether the op log gets projected in. It is
/// **not** "the file did not exist a moment ago": a replay that threw leaves the
/// store created but unpopulated, and keying off creation alone would skip the
/// retry for ever, leaving reduced state stranded in a log nothing reads. The
/// answer is the absence of [domainRebuildMarkerFileName], which only a completed
/// replay writes — so a failed one is retried on the next launch, and a store
/// deleted out from under the app is replayed into again (a fresh create clears a
/// stale marker).
///
/// [markRebuilt] is the write of that marker, called by the replay's one caller
/// (`providers/database_provider.dart`) on success and nowhere else.
typedef DomainStoreOpening = ({
  SqliteDatabase database,
  bool needsRebuild,
  void Function() markRebuilt,
});

class DomainStoreImpl {
  /// Open (creating on first run) the domain store in the app documents
  /// directory.
  Future<DomainStoreOpening> openDatabase() async =>
      openDomainStoreIn((await getApplicationDocumentsDirectory()).path);
}

/// The whole of the open path, over an explicit [directoryPath].
///
/// Split out from [DomainStoreImpl.openDatabase] so the behaviour that matters —
/// the replay gate and the legacy file's disposal — is testable against a temp
/// directory instead of only on a device.
Future<DomainStoreOpening> openDomainStoreIn(String directoryPath) async {
  final file = File(p.join(directoryPath, domainStoreFileName));
  // Before the open, which creates it. `-wal`/`-shm` are irrelevant here: a
  // sidecar without its main file is not a store.
  final createdFresh = !file.existsSync();
  final marker = File(p.join(directoryPath, domainRebuildMarkerFileName));
  // A store that was just created has never been replayed into, whatever a
  // leftover marker claims — so the marker follows the file rather than
  // outliving it.
  if (createdFresh && marker.existsSync()) {
    try {
      marker.deleteSync();
    } on FileSystemException {
      // Best-effort: a marker that cannot be cleared costs one skipped replay
      // into a store that is empty anyway, not a broken app.
    }
  }
  final needsRebuild = !marker.existsSync();

  final database = SqliteDatabase(path: file.path);
  await database.initialize();

  deleteLegacyPowerSyncStore(directoryPath);

  return (
    database: database,
    needsRebuild: needsRebuild,
    markRebuilt: () => marker.writeAsStringSync(
      'The op log has been projected into $domainStoreFileName.\n',
      flush: true,
    ),
  );
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
