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
/// **Deterministic entity ids are the exception, and there are exactly three
/// families.**
///
/// 1. [preferenceEntityId] — a policy of the `user_preferences` KV collection.
///    Deriving the entity id from the key means two devices creating the same
///    preference offline converge as one entity under field-grain LWW instead
///    of forking into two rows.
/// 2. **Junction collections** — `todo_tags`, `capture_outcomes`,
///    `capture_tags`, `focus_session_tasks`, `focus_session_dispositions`.
///    Their domain identity *is* the relation, and the shipped DAOs already
///    derive their row ids as `uuid5` of the pair ([todoTagIdFor] and its
///    siblings) precisely so concurrent or replayed assignment collapses onto
///    one row. The op log carries that identity forward: two devices assigning
///    the same tag offline converge as one junction entity rather than forking.
///    Only [focusSessionTaskIdFor] is new (#550); the DAO mints the row under it
///    like its four siblings, and the domain projector still rewrites the column
///    for rows a pre-#550 device created at random.
/// 3. **Entities a person created by typing into a vault page** — an Action
///    ([vaultHandEditedActionIdFor]) and a Tag ([vaultHandEditedTagIdFor]).
///    Their identity is what was typed, so two devices that read the same hand
///    edit create one entity rather than one each. ADR-0019 is the precedent.
///
/// Every other collection — Outcomes, Actions, Tags, Captures, FocusSessions,
/// TimeLogs — keeps client-generated random UUIDs and must not copy any of
/// these exceptions.
///
/// **The Tag case is narrow, and it is the one ADR-0043 names as forbidden.**
/// A Tag the *app* creates keeps its client-random id: that is what lets two
/// devices each create "Alice"/`person` offline fork, and be folded afterwards
/// by `DomainReconciler`. Only a Tag that exists because a person typed its
/// name into a page is derived, and only so that the page means the same thing
/// on every device. The reconciler's fold is what collapses it with an
/// app-created Tag of the same name afterwards.
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
/// `focusSessionDispositionIdFor`, and minted into the local `id` column by
/// `FocusSessionDao.openSession` exactly as those four are. The domain
/// projector realigns the column as well, which is what carries a Plan row a
/// pre-#550 device created at random onto the same id every other device holds.
String focusSessionTaskIdFor(String sessionId, String taskId) =>
    _uuid.v5(Namespace.url.value, 'jeeves://focus_session_task/$sessionId/$taskId');

/// Deterministic `actions` entity id for a checklist line a person typed into a
/// vault page by hand: the Outcome, the line's text, and its ordinal among
/// identical new lines. Two devices that read the same hand edit then create one
/// Action, not two. A third derived case beside the junction pairs (ADR-0019
/// is the precedent); every other Action keeps a random id.
String vaultHandEditedActionIdFor(String outcomeId, String text, int ordinal) =>
    _uuid.v5(Namespace.url.value, 'jeeves://vault_action/$outcomeId/$ordinal/$text');

/// Deterministic `tags` entity id for a Tag a person typed into a vault page by
/// hand: its kind and its name.
///
/// The narrow exception ADR-0043 names as forbidden, and the reason is narrow
/// too: a Tag the *app* creates keeps a client-random id, so two devices that
/// each create "Alice"/`person` offline fork and `DomainReconciler` folds them
/// afterwards. A Tag that exists only because a person typed its name into a
/// page has no other identity to converge on — the page is what both devices
/// read — so it is named after what was typed, and the same fold collapses it
/// with an app-created Tag of the same name if there is one.
String vaultHandEditedTagIdFor(String name, String type) =>
    _uuid.v5(Namespace.url.value, 'jeeves://vault_tag/$type/$name');

/// Deterministic `todo_tags` entity id for the (Outcome, Tag) pair.
///
/// The junction family's home is here, so that a plugin which has to name a
/// link — the vault, when a person types a label into a page — derives it the
/// way the app does without reaching into the DAO layer. The derivation is
/// unchanged: the same string, the same namespace, the same ids.
String todoTagIdFor(String todoId, String tagId) =>
    _uuid.v5(Namespace.url.value, 'jeeves://todo_tag/$todoId/$tagId');

/// Deterministic `capture_tags` entity id for the (Capture, Tag) pair.
///
/// The sibling of [todoTagIdFor], for the same reason.
String captureTagIdFor(String captureId, String tagId) =>
    _uuid.v5(Namespace.url.value, 'jeeves://capture_tag/$captureId/$tagId');
