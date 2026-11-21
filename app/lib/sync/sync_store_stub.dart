// Stub opener for the op-log store — compiled when dart:io is absent (web).
//
// It exists so the analyser can resolve [SyncStoreImpl] on every platform, and
// so a web build compiles without pretending to carry the op-log stack. A
// browser reaching this throws rather than silently running on a store that is
// not there.
import 'sync_database.dart';

/// The file the op log lives in, beside the domain store and never inside it.
///
/// Declared here as well as in the native opener, so the name resolves on
/// every platform — the same rule `database/domain_store_stub.dart` follows
/// for the domain store's file name.
const String syncStoreFileName = 'jeeves_sync.sqlite';

class SyncStoreImpl {
  Future<SyncDatabase> openDatabase() {
    throw UnsupportedError(
      'The op-log sync store has no web implementation: the fleet '
      'is one Android phone. Run the enrolment ceremony on the device.',
    );
  }
}
