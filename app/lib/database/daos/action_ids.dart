/// Deterministic id derivation for backfilled Actions (ADR-0019, issue #471).
///
/// Story 1 has no `ActionDao` yet — the only writer of `actions` rows is the
/// Drift v26 backfill — but the id scheme lives here, in the DAO layer, so the
/// migration step and its tests share one definition (the `todoTagIdFor` /
/// `captureOutcomeIdFor` pattern).
library;

import 'package:powersync/powersync.dart' show uuid;
import 'package:uuid/enums.dart' show Namespace;

/// The deterministic id of the `current` Action backfilled from an Outcome's
/// next-action cursor.
///
/// `uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todoId>")` — byte-identical
/// to the Python `_backfill_action_id_for` in Alembic 0028, so the server and
/// client backfills mint the **same** row and ADR-0015 upsert-on-replay
/// collapses the duplicate upload. The scheme keys on the Outcome (not on
/// content), so re-running either backfill can never mint a second Action for
/// the same Outcome. A shared golden vector pins the cross-language equality.
String backfillActionIdFor(String todoId) =>
    uuid.v5(Namespace.url.value, 'jeeves://action/backfill/$todoId');
