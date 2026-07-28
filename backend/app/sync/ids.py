"""Deterministic id derivations shared by every device and by the server.

Both derivations are stubs with a deliberate shape.  ``implicit_workspace_id``
stands in for the Workspace genesis control op that #549 introduces: until a
Workspace is a signed fact, N devices of one User must be able to agree on a
Workspace id with no registration round-trip, and a UUIDv5 of the user id is
the cheapest way to do that.  ``preference_entity_id`` is a policy of the
``user_preferences`` KV collection *only* — deriving the entity id from the key
means two devices creating the same preference offline converge as one entity
under field-grain LWW instead of forking into two rows.  Collections whose
entities are created once, on one device (#550), keep client-generated random
UUIDs and must not copy this.

These constants live in the golden vectors, so they are protocol identity, not
implementation detail.
"""

from __future__ import annotations

import uuid
from typing import Final

#: uuid5(NAMESPACE_URL, "https://jeeves.app/sync/workspace/v1"), frozen.
JEEVES_WORKSPACE_NAMESPACE: Final = uuid.UUID("e9d4afd3-87e4-5450-bd7d-4fc191ff3857")

#: The one collection this slice carries end to end.
USER_PREFERENCES_COLLECTION: Final = "user_preferences"


def implicit_workspace_id(user_id: str) -> uuid.UUID:
    """The single implicit Workspace every Device of ``user_id`` is granted."""
    return uuid.uuid5(JEEVES_WORKSPACE_NAMESPACE, user_id)


def preference_entity_id(workspace_id: uuid.UUID, preference_key: str) -> uuid.UUID:
    """The ``user_preferences`` entity id for ``preference_key``."""
    return uuid.uuid5(workspace_id, preference_key)
