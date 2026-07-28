/// Deterministic id derivations shared by every device and by the server.
///
/// Mirror of `backend/app/sync/ids.py`; both are pinned by the golden vectors,
/// so these are protocol identity rather than implementation detail.
///
/// [implicitWorkspaceId] stands in for the Workspace genesis control op that
/// #549 introduces: until a Workspace is a signed fact, N devices of one User
/// must agree on a Workspace id with no registration round-trip.
///
/// **Deterministic entity ids are the exception, and there are exactly two.**
///
/// 1. [preferenceEntityId] — a policy of the `user_preferences` KV collection.
///    Deriving the entity id from the key means two devices creating the same
///    preference offline converge as one entity under field-grain LWW instead
///    of forking into two rows.
/// 2. **Junction collections** — `todo_tags`, `capture_outcomes`,
///    `capture_tags`, `focus_session_tasks`, `focus_session_dispositions`.
///    Their domain identity *is* the relation, and the shipped DAOs already
///    derive their row ids as `uuid5` of the pair (`todoTagIdFor` and its
///    siblings) precisely so concurrent or replayed assignment collapses onto
///    one row. The op log carries that identity forward: two devices assigning
///    the same tag offline converge as one junction entity rather than forking.
///    Only [focusSessionTaskIdFor] is new — the table's local `id` column is
///    random today, and the domain projector rewrites it to this derivation on
///    every device (#550).
///
/// Every other collection — Outcomes, Actions, Tags, Captures, FocusSessions,
/// TimeLogs — keeps client-generated random UUIDs and must not copy either
/// exception.
///
/// **One store per Workspace, recorded.** The pair derivations contain no
/// workspace id; they are collision-safe because a given entity pair exists in
/// exactly one Workspace's store. A store that ever spanned Workspaces would
/// need a workspace-scoped namespace and a v2 derivation.
library;

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// uuid5(NAMESPACE_URL, "https://jeeves.app/sync/workspace/v1"), frozen.
const String jeevesWorkspaceNamespace = 'e9d4afd3-87e4-5450-bd7d-4fc191ff3857';

/// The one collection this slice carries end to end.
const String userPreferencesCollection = 'user_preferences';

/// The single implicit Workspace every Device of [userId] is granted.
String implicitWorkspaceId(String userId) =>
    _uuid.v5(jeevesWorkspaceNamespace, userId);

/// The `user_preferences` entity id for [preferenceKey].
String preferenceEntityId(String workspaceId, String preferenceKey) =>
    _uuid.v5(workspaceId, preferenceKey);

/// Deterministic `focus_session_tasks` entity id for the (session, task) pair.
///
/// The new member of the junction family, derived on the same scheme as the
/// shipped `todoTagIdFor` / `captureOutcomeIdFor` / `captureTagIdFor` /
/// `focusSessionDispositionIdFor`. Unlike those four, the local `id` column is
/// still minted at random by `FocusSessionDao.openSession`; the domain
/// projector rewrites it to this value on every device so a Plan authored on
/// one device and replayed on another carries byte-identical rows.
String focusSessionTaskIdFor(String sessionId, String taskId) =>
    _uuid.v5(Namespace.url.value, 'jeeves://focus_session_task/$sessionId/$taskId');
