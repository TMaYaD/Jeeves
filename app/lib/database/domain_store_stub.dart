// Stub opener for the domain store — compiled when dart:io is absent (web).
//
// It exists so the analyser can resolve [DomainStoreImpl] on every platform, and
// so a web build compiles without pretending to carry an on-disk store. A browser
// reaching this throws rather than silently running on a store that is not there.
import 'package:sqlite_async/sqlite_async.dart';

const String domainStoreFileName = 'jeeves_domain.sqlite';
const String domainRebuildMarkerFileName = 'jeeves_domain.rebuilt';

typedef DomainStoreOpening = ({
  SqliteDatabase database,
  bool needsRebuild,
  void Function() markRebuilt,
});

class DomainStoreImpl {
  Future<DomainStoreOpening> openDatabase() {
    throw UnsupportedError(
      'The domain store has no web implementation: the fleet is one Android '
      'phone. Run the app on the device.',
    );
  }
}

Future<DomainStoreOpening> openDomainStoreIn(String directoryPath) =>
    DomainStoreImpl().openDatabase();
