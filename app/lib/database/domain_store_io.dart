// Native opener for the domain read model's store (Android, iOS, macOS, Linux,
// Windows).
//
// Selected by the conditional export in domain_store.dart when dart:io is
// available. All dart:io and path_provider usage is confined here so the rest of
// the codebase compiles on web.
//
// It opens a file Drift owns outright (ADR-0035) and reports whether it had to
// create it. It also sweeps up one dead file name on the way past — see
// [removeDeadStoreFile], which is housekeeping and not a decision.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// The domain read model's file. Drift creates and migrates it; nothing else
/// writes it.
const String domainStoreFileName = 'jeeves_domain.sqlite';

/// A file name nothing in this build writes, reads, or can open.
///
/// It belonged to a replication engine that is no longer a dependency, and its
/// contents were views over that engine's own internal tables — so no code here
/// could read it even if it wanted to. Nothing depends on these bytes, which is
/// the whole of the argument for deleting them; see [removeDeadStoreFile].
const String deadStoreFileName = 'jeeves.sqlite';

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
/// the replay gate, and the housekeeping sweep — is testable against a temp
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

  // Housekeeping, deliberately after the open and deliberately ignored: the
  // return value below is identical whether this removed anything, failed, or
  // found nothing. Nothing downstream may treat it as having happened.
  removeDeadStoreFile(directoryPath);

  return (
    database: database,
    needsRebuild: needsRebuild,
    markRebuilt: () => marker.writeAsStringSync(
      'The op log has been projected into $domainStoreFileName.\n',
      flush: true,
    ),
  );
}

/// Unlink [deadStoreFileName] and its SQLite sidecars, if they are there.
///
/// **Housekeeping, not a decision.** It reads nothing and asks nothing — not the
/// enrolment state, not the op log, not the file's contents — and the caller
/// proceeds identically whether it removed three files, one, or none. It has no
/// arms, and it must not grow any: the moment this function's behaviour depends
/// on something about the device, it is a migration wearing a sweep's clothes
/// and belongs somewhere it can be reasoned about.
///
/// The claim that makes it safe is a claim about the *build*, not the caller: no
/// code in this app can open that file, so nothing can be depending on it. That
/// is unconditional. An earlier version of this argued the deletion was
/// recoverable because the op log could be replayed — which was true only for a
/// device that had one, and false for exactly the device it cost.
///
/// Idempotent, and best-effort per file: absence is a no-op, and a file that
/// cannot be unlinked is wasted disk rather than a broken app.
void removeDeadStoreFile(String directoryPath) {
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File(p.join(directoryPath, '$deadStoreFileName$suffix'));
    if (!file.existsSync()) continue;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Best-effort.
    }
  }
}
