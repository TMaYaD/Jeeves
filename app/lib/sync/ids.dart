/// Deterministic id derivations shared by every device and by the server.
///
/// Mirror of `backend/app/sync/ids.py`; both are pinned by the golden vectors,
/// so these are protocol identity rather than implementation detail.
///
/// **Two implicit Workspaces per User, both derivation-addressed.** Derivation
/// keeps N devices agreeing on a Workspace id with no round-trip; the
/// `workspace_genesis` control op is what makes the Workspace's *existence* a
/// signed fact. The pair is [defaultWorkspaceId] (the GTD system) and
/// [userPreferencesWorkspaceId] (User-global settings). Preferences are a
/// Workspace of their own rather than a collection inside the default one
/// because the boundary is structural: every Device is granted it and no Service
/// ever is, so a preference cannot leak through a Service grant.
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

/// uuid5(NAMESPACE_URL, "https://jeeves.app/sync/workspace/user-preferences/v1"),
/// frozen. A namespace of its own rather than a second key inside the default
/// one: the two ids must be independent, so neither can be computed from the
/// other by a client that only knows one.
///
/// A literal, like its sibling above, rather than the `uuid5` call that produced
/// it: Workspace identity is protocol, and recomputing it at runtime would make
/// it depend on the `uuid` package's v5 implementation staying byte-stable
/// forever. The URL it derives from stays in the doc as the derivation of record.
const String userPreferencesWorkspaceNamespace = 'c2b38d21-5518-5ad6-88b1-cc253ab3495f';

/// The collection the `user_preferences` Workspace carries.
const String userPreferencesCollection = 'user_preferences';

/// The GTD Workspace every Device of [userId] is granted.
String defaultWorkspaceId(String userId) => _uuid.v5(jeevesWorkspaceNamespace, userId);

/// The User-global preferences Workspace: every Device, never a Service.
String userPreferencesWorkspaceId(String userId) =>
    _uuid.v5(userPreferencesWorkspaceNamespace, userId);

/// Every Workspace id [userId] can reach without a Grant round-trip.
///
/// The v1 anti-junk-workspace rule: genesis is only accepted for an id in this
/// set, so a stolen credential cannot fill the log with Workspaces nobody asked
/// for. Real user-created Workspaces lift this.
List<String> derivableWorkspaceIds(String userId) =>
    [defaultWorkspaceId(userId), userPreferencesWorkspaceId(userId)];

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
