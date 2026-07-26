/// Deterministic id derivation for backfilled Actions (ADR-0019, issue #471).
///
/// The client no longer runs a backfill of its own — the Drift v26 backfill
/// that once called this was deleted with the `todos.next_action_text` column
/// it read (ADR-0024, issue #525). The derivation stays here, in the DAO layer,
/// because it is the contract the **server** backfill (Alembic 0028) mints
/// against: the golden vector in `action_backfill_id_test.dart` is the client
/// half of a cross-language equality that ADR-0019 rests on. It also serves as
/// a stable-id helper for tests that need to name a backfilled Action.
library;

import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

/// The deterministic id of the `current` Action backfilled from an Outcome's
/// next-action cursor.
///
/// `uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todoId>")` — byte-identical
/// to the Python `_backfill_action_id_for` in Alembic 0028, so any origin
/// deriving a backfilled Action mints the **same** row and ADR-0015
/// upsert-on-replay collapses the duplicate upload. The scheme keys on the
/// Outcome (not on content), so re-running the backfill can never mint a second
/// Action for the same Outcome. A shared golden vector pins the cross-language
/// equality.
String backfillActionIdFor(String todoId) =>
    uuid.v5(Namespace.url.value, 'jeeves://action/backfill/$todoId');
