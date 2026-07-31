/// A file-backed store that dies mid-write, so a crash between two of a control
/// op's writes can be staged in a unit test.
///
/// #618's control-op apply raises the epoch floor and appends the applied-control
/// record inside **one** transaction. Failing the applied-control insert aborts
/// that transaction *after* the floor was raised, so the store lands in exactly
/// the "interrupted between the floor raise and the applied-control append" state
/// the fix has to survive. The failure is a `SqliteException` with an I/O — not a
/// constraint — result code, so the receive pipeline rethrows it rather than
/// mislabelling it a taken slot, the pull cursor never advances, and the op is
/// re-served on the next pull.
///
/// Fault injection lives at the store (a bad disk) rather than behind a seam in
/// `SyncClient`: the client runs its real, unaltered code, which is the whole
/// point of a crash-recovery test.
library;

import 'package:drift/drift.dart';
import 'package:sqlite3/common.dart' show SqlExtendedError, SqliteException;

/// A [QueryInterceptor] that fails the next insert into [tableName] once armed.
class StoreWriteFault extends QueryInterceptor {
  StoreWriteFault(this.tableName);

  /// Matched as a substring of the SQL, which is how drift spells the target —
  /// `INSERT INTO "applied_control_log" …`. Only that table's inserts carry the
  /// name, so nothing else is caught.
  final String tableName;

  /// Set by the test immediately before the write it means to interrupt, and
  /// cleared as the fault fires so only the first matching insert is failed —
  /// the recovering pull that follows must be allowed to complete.
  bool armed = false;

  /// Whether the fault has fired. A test asserts on it so an apply that never
  /// reached the guarded insert fails loudly instead of passing vacuously.
  bool fired = false;

  /// Wrap [inner] so its inserts pass through this fault.
  QueryExecutor wrap(QueryExecutor inner) => inner.interceptWith(this);

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (armed && statement.contains(tableName)) {
      armed = false;
      fired = true;
      throw SqliteException(
        extendedResultCode: SqlExtendedError.SQLITE_IOERR_WRITE,
        message: 'simulated device death while writing to $tableName',
      );
    }
    return super.runInsert(executor, statement, args);
  }
}
