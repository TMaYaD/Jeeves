/// The columns the sync store gained at v12, and how to take them away again.
///
/// A migration fixture rewinds a store to an older version by opening it at
/// the current schema and removing the parts that version did not have. For a
/// table that is a `DROP TABLE`; for a column it is a `DROP COLUMN`, which
/// SQLite has understood since 3.35.
///
/// The rows stay. A store that predates the decision holds no decision, and
/// the columns read null there anyway — the migration's job is to give it the
/// columns, not to decide anything.
library;

import 'package:jeeves/sync/sync_database.dart';

/// The columns v12 added, as `(table, column)` pairs.
const List<(String, String)> v12Columns = [
  ('integrity_alarms', 'resolution'),
  ('integrity_alarms', 'resolution_decided_at'),
  ('integrity_alarms', 'repost_from_author_seq'),
  ('quarantined_ops', 'resolution'),
  ('quarantined_ops', 'resolution_decided_at'),
];

/// Take the v12 columns out of [database], so the store it holds is the shape
/// a device from before v12 would have.
Future<void> dropV12Columns(SyncDatabase database) async {
  for (final (table, column) in v12Columns) {
    await database.customStatement('ALTER TABLE $table DROP COLUMN $column');
  }
}
