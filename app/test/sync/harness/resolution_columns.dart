/// The columns the sync store gained to carry a resolution, and how to take
/// them away again.
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

/// The columns each schema version added, as `(table, column)` pairs.
///
/// Keyed by the version that added them, so a fixture rewound to [version]
/// drops every column a later version brought and keeps the ones it had.
/// Adding a version here is what keeps the fixtures honest: without it the
/// fixture keeps a column the migration is about to add, and the upgrade
/// fails on a duplicate column rather than on the thing it was meant to test.
const Map<int, List<(String, String)>> columnsAddedAt = {
  14: [
    ('integrity_alarms', 'resolution'),
    ('integrity_alarms', 'resolution_decided_at'),
    ('integrity_alarms', 'repost_from_author_seq'),
    ('quarantined_ops', 'resolution'),
    ('quarantined_ops', 'resolution_decided_at'),
  ],
  15: [
    ('quarantined_ops', 'resolution_projected_at'),
  ],
  17: [
    ('sync_cursors', 'rebuild_required_at'),
  ],
};

/// Take out of [database] every column that a store at [version] did not have,
/// so the store it holds is the shape a device from before [version] would
/// have.
///
/// The tables a later version added are the fixture's own business — it drops
/// them by hand, because only the fixture knows which table it is about.
Future<void> dropColumnsAddedAfter(SyncDatabase database, int version) async {
  // v13 added the vault's table; a store from before it does not hold it.
  if (version < 13) {
    await database.customStatement('DROP TABLE IF EXISTS vault_page_bases');
  }
  // v16 added the record of reduced entities that still need projecting; a
  // store from before it does not hold it.
  if (version < 16) {
    await database.customStatement(
      'DROP TABLE IF EXISTS entities_awaiting_projection',
    );
  }
  for (final entry in columnsAddedAt.entries) {
    if (entry.key <= version) continue;
    for (final (table, column) in entry.value) {
      await database.customStatement('ALTER TABLE $table DROP COLUMN $column');
    }
  }
}
