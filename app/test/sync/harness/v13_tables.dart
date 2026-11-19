/// The table the sync store gained at v13, and how to take it away again.
///
/// A migration fixture rewinds a store to an older version by opening it at
/// the current schema and removing the parts that version did not have. For a
/// table that is a `DROP TABLE`.
///
/// The rows go with it. A store that predates the decision has accepted no
/// hole, and the migration's job is to give it the table, not to decide
/// anything for it.
library;

import 'package:jeeves/sync/sync_database.dart';

/// Take the v13 table out of [database], so the store it holds is the shape a
/// device from before v13 would have.
Future<void> dropV13Tables(SyncDatabase database) async {
  await database.customStatement('DROP TABLE accepted_chain_holes');
}
