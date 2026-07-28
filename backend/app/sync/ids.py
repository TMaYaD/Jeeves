"""Deterministic id derivations shared by every device and by the server.

**Two implicit Workspaces per User, both derivation-addressed.**  Derivation
keeps N devices agreeing on a Workspace id with no round-trip; the
``workspace_genesis`` control op is what makes the Workspace's *existence* a
signed fact.  The pair is:

* :func:`default_workspace_id` — the GTD system.
* :func:`user_preferences_workspace_id` — User-global settings.  Every Device is
  granted it and no Service ever is, which is why it is a Workspace of its own
  rather than a collection inside the default one: the boundary is structural,
  so a preference cannot leak through a Service grant.

``preference_entity_id`` is a policy of the ``user_preferences`` KV collection
*only* — deriving the entity id from the key means two devices creating the same
preference offline converge as one entity under field-grain LWW instead of
forking into two rows.  Collections whose entities are created once, on one
device (#550), keep client-generated random UUIDs and must not copy this.

These constants live in the golden vectors, so they are protocol identity, not
implementation detail.
"""

from __future__ import annotations

import uuid
from typing import Final

#: uuid5(NAMESPACE_URL, "https://jeeves.app/sync/workspace/v1"), frozen.
JEEVES_WORKSPACE_NAMESPACE: Final = uuid.UUID("e9d4afd3-87e4-5450-bd7d-4fc191ff3857")

#: uuid5(NAMESPACE_URL, "https://jeeves.app/sync/workspace/user-preferences/v1"),
#: frozen.  A namespace of its own rather than a second key inside the default
#: one: the two ids must be independent, so neither can be computed from the
#: other by a client that only knows one.
USER_PREFERENCES_WORKSPACE_NAMESPACE: Final = uuid.uuid5(
    uuid.NAMESPACE_URL, "https://jeeves.app/sync/workspace/user-preferences/v1"
)

#: The collection the ``user_preferences`` Workspace carries.
USER_PREFERENCES_COLLECTION: Final = "user_preferences"


def default_workspace_id(user_id: str) -> uuid.UUID:
    """The GTD Workspace every Device of ``user_id`` is granted."""
    return uuid.uuid5(JEEVES_WORKSPACE_NAMESPACE, user_id)


def user_preferences_workspace_id(user_id: str) -> uuid.UUID:
    """The User-global preferences Workspace: every Device, never a Service."""
    return uuid.uuid5(USER_PREFERENCES_WORKSPACE_NAMESPACE, user_id)


def derivable_workspace_ids(user_id: str) -> frozenset[uuid.UUID]:
    """Every Workspace id a ``user_id`` can reach without a Grant round-trip.

    The v1 anti-junk-workspace rule: genesis is only accepted for an id in this
    set, so a stolen credential cannot fill the log with Workspaces nobody asked
    for.  Real user-created Workspaces lift this and will carry their own
    server-side existence check.
    """
    return frozenset({default_workspace_id(user_id), user_preferences_workspace_id(user_id)})


def preference_entity_id(workspace_id: uuid.UUID, preference_key: str) -> uuid.UUID:
    """The ``user_preferences`` entity id for ``preference_key``."""
    return uuid.uuid5(workspace_id, preference_key)
