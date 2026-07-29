// Native opener for the op-log store (Android, iOS, macOS, Linux, Windows).
//
// Production sync wiring (#553 Phase 2).
//
// Selected by the conditional export in sync_store.dart when dart:io is
// available. All dart:io and path_provider usage is confined here so the rest of
// the sync stack compiles on web.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sync_database.dart';

/// The file the op log lives in, beside PowerSync's `jeeves.sqlite` and never
/// inside it.
///
/// A separate file, deliberately: the op-log store is Drift-native and owns its
/// own connection, while `jeeves.sqlite` is opened by PowerSync's
/// `sqlite_async` stack and shared with `GtdDatabase` through
/// `drift_sqlite_async`. Putting the two in one file would put a Drift migrator
/// in charge of PowerSync's schema, and #556 deletes PowerSync's file outright —
/// which must not take the op log with it.
const String syncStoreFileName = 'jeeves_sync.sqlite';

class SyncStoreImpl {
  /// Open (creating on first run) the op-log store.
  ///
  /// `createInBackground` rather than `NativeDatabase.new`: every statement then
  /// runs on a background isolate, so a pull that reduces a page of ops does not
  /// compete with the UI isolate for frames.
  Future<SyncDatabase> openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    return SyncDatabase(
      NativeDatabase.createInBackground(
        File(p.join(directory.path, syncStoreFileName)),
      ),
    );
  }
}
