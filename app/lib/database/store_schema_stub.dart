// Stub reader for the two local stores' schema versions — compiled when
// dart:io is absent (web).
//
// It exists so the analyser can resolve the reader on every platform, and so a
// web build compiles without pretending to carry an on-disk store. A browser
// reaches this rather than silently reporting a version it never read.
import 'store_file_probe.dart';

Future<({StoreFileProbe domainStore, StoreFileProbe syncStore})>
    readStoreFileProbes() async {
  throw UnsupportedError(
    'The local stores have no web implementation: the fleet is one Android '
    'phone. Run the app on the device.',
  );
}

Future<({StoreFileProbe domainStore, StoreFileProbe syncStore})>
    readStoreFileProbesIn(String directoryPath) async {
  throw UnsupportedError(
    'The local stores have no web implementation: the fleet is one Android '
    'phone. Run the app on the device.',
  );
}
