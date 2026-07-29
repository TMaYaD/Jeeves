// Native opener for the reseed verification's throwaway stores.
//
// **Cutover tooling — removed by #556.**
//
// In memory, both of them, and that is the point: the verification reduces the
// server log from zero and then throws the result away, so a file would only be
// a thing to clean up. Nothing here shares a connection with the live op-log
// store or with PowerSync's `jeeves.sqlite` — a scratch stack that touched
// either would be writing to the very stores the run must not disturb.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';

import '../../database/gtd_database.dart';
import '../../sync/sync_database.dart';

class ReseedScratchStoreImpl {
  /// A fresh op-log store for one Workspace's verification.
  SyncDatabase openSyncDatabase() {
    _allowMultipleDatabases();
    return SyncDatabase(NativeDatabase.memory());
  }

  /// A fresh domain read model for the scratch projector to write into.
  ///
  /// The default [NoopDomainOpCapture] is kept deliberately: this store is a read
  /// model being *filled*, and a capture seam wired to a client would tee the
  /// projector's own writes straight back into an outbox.
  GtdDatabase openDomainDatabase() {
    _allowMultipleDatabases();
    return GtdDatabase(NativeDatabase.memory());
  }

  /// Drift warns when several databases share one executor. Each store opened
  /// here has its own in-memory connection, so there is nothing to race — and the
  /// live stores are already open by the time a reseed runs.
  static void _allowMultipleDatabases() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  }
}
