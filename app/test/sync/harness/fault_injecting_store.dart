/// A [QueryInterceptor] that fails one chosen write, on demand.
///
/// The receive pipeline's atomicity (#618) can only be asserted by killing a
/// write *mid-apply* and proving the store recovers. `interceptWith` wraps a
/// real executor — and, crucially, the transaction executors it hands out — so a
/// throw from [runInsert] here lands inside `SyncClient`'s receive transaction
/// exactly as a real `SQLITE_FULL`/`SQLITE_IOERR` would, and drift rolls the unit
/// back around it.
///
/// It arms a *single* fault: the next insert whose statement names the target
/// table throws once, then the injector disarms itself. Everything else — and
/// every write once disarmed — passes straight through. The fault is armed
/// **after** a device has enrolled (enrolment's own control writes must land
/// cleanly), so the store is built with a disarmed injector and armed only for
/// the write the test means to interrupt.
library;

import 'package:drift/drift.dart';
import 'package:sqlite3/common.dart' show SqliteException;

/// A non-slot-taken extended result code, so the injected fault is classified as
/// a genuine storage fault (the rollback path) rather than an author-chain slot
/// collision. `SQLITE_IOERR` is `10`.
const int _sqliteIoerr = 10;

class FaultInjectingInterceptor extends QueryInterceptor {
  /// The table name that, when its next insert runs, should throw — or null when
  /// disarmed. Matched as a substring of the statement, which for a drift insert
  /// is `INSERT INTO "table" (...)`.
  String? _failNextInsertIntoTable;

  /// How many faults this injector has thrown, so a test can assert the write it
  /// meant to interrupt was actually reached.
  int firedCount = 0;

  /// Arm the injector: the next insert into [table] throws a [SqliteException]
  /// once, then disarms. Names a table rather than a statement so a test says
  /// *which durable effect* it is interrupting, not how drift spells the SQL.
  void failNextInsertInto(String table) {
    _failNextInsertIntoTable = table;
  }

  /// Drop any armed fault. Writes pass through untouched from here on.
  void disarm() {
    _failNextInsertIntoTable = null;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    final target = _failNextInsertIntoTable;
    if (target != null && statement.contains('"$target"')) {
      _failNextInsertIntoTable = null;
      firedCount++;
      throw SqliteException(
        extendedResultCode: _sqliteIoerr,
        message: 'fault injected before inserting into "$target"',
        operation: 'executing a statement',
        causingStatement: statement,
      );
    }
    return super.runInsert(executor, statement, args);
  }
}
