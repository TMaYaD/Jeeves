/// Deterministic id derivations shared by every device and by the server.
///
/// Mirror of `backend/app/sync/ids.py`; both are pinned by the golden vectors,
/// so these are protocol identity rather than implementation detail.
///
/// Both derivations are stubs with a deliberate shape.
/// [implicitWorkspaceId] stands in for the Workspace genesis control op that
/// #549 introduces: until a Workspace is a signed fact, N devices of one User
/// must agree on a Workspace id with no registration round-trip.
/// [preferenceEntityId] is a policy of the `user_preferences` KV collection
/// **only** — deriving the entity id from the key means two devices creating
/// the same preference offline converge as one entity under field-grain LWW
/// instead of forking into two rows. Collections whose entities are created
/// once, on one device (#550), keep client-generated random UUIDs and must not
/// copy this.
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
