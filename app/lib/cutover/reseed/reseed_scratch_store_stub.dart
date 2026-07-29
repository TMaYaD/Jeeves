// Stub opener for the reseed verification's throwaway stores — compiled when
// dart:io is absent (web).
//
// **Cutover tooling — removed by #556.**
//
// It exists so the analyser resolves [ReseedScratchStoreImpl] on every platform,
// and so a web build compiles without pretending to carry the cutover tooling.
// The #553 fleet is one Android phone; a browser reaching this throws rather than
// silently verifying against stores that are not there.
import '../../database/gtd_database.dart';
import '../../sync/sync_database.dart';

class ReseedScratchStoreImpl {
  SyncDatabase openSyncDatabase() => throw UnsupportedError(_message);

  GtdDatabase openDomainDatabase() => throw UnsupportedError(_message);

  static const String _message =
      'The reseed verification has no web implementation: the #553 cutover '
      'fleet is one Android phone. Run the reseed on the device.';
}
