// Web PowerSync storage adapter (OPFS-backed SQLite in the browser).
//
// Selected by the conditional export in powersync_storage.dart when
// dart:html is available.  Uses WebPowerSyncOpenFactory from
// package:powersync/web.dart, which opens the database through the
// OPFS-backed sqlite3.wasm worker defined in app/web/.
//
// Prerequisites (handled by tool/fetch_web_assets.sh via `make setup`):
//   app/web/sqlite3.wasm              — OPFS-capable SQLite WASM binary
//   app/web/powersync_db.worker.js    — PowerSync web DB worker
//
// COOP/COEP headers must be set by the server for OPFS and SharedArrayBuffer
// to be available.  See docs/ARCHITECTURE.md §"Platform I/O Adapters".
import 'package:powersync/powersync.dart' as ps;
import 'package:powersync/web.dart';

class PowerSyncStorageImpl {
  Future<ps.PowerSyncDatabase> openDatabase(ps.Schema schema) async {
    // powerSyncDefaultSqliteOptions points to:
    //   wasmUri:   'sqlite3.wasm'
    //   workerUri: 'powersync_db.worker.js'
    // These match the assets downloaded by tool/fetch_web_assets.sh.
    final db = ps.PowerSyncDatabase.withFactory(
      WebPowerSyncOpenFactory(
        path: 'jeeves',
        sqliteOptions: ps.powerSyncDefaultSqliteOptions,
      ),
      schema: schema,
    );
    await db.initialize();
    return db;
  }
}
