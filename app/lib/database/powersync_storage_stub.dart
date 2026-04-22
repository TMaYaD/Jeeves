import 'package:powersync/powersync.dart' as ps;

// Stub — compiled only when neither dart:io (native) nor dart:html (web) is
// available.  In practice this path is never reached; it exists so that the
// Dart analyser can resolve [PowerSyncStorageImpl] on all platforms without
// compile errors.
class PowerSyncStorageImpl {
  Future<ps.PowerSyncDatabase> openDatabase(ps.Schema schema) {
    throw UnsupportedError(
      'No PowerSyncStorage implementation is available for this platform.',
    );
  }
}
