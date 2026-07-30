// Stub opener for the op-log store — compiled when dart:io is absent (web).
//
// It exists so the analyser can resolve [SyncStoreImpl] on every platform, and
// so a web build compiles without pretending to carry the op-log stack. A
// browser reaching this throws rather than silently running on a store that is
// not there.
import 'sync_database.dart';

class SyncStoreImpl {
  Future<SyncDatabase> openDatabase() {
    throw UnsupportedError(
      'The op-log sync store has no web implementation: the fleet '
      'is one Android phone. Run the enrolment ceremony on the device.',
    );
  }
}
