"""The fan-out primitive, away from any socket.

Everything the signal protocol promises about coalescing, Workspace isolation and
member-scoped revocation is a property of this class; the socket tests then prove
the route uses it as advertised.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Coroutine
from typing import Any

from app.sync.signal_hub import SignalHub


async def _never_completes(awaitable: Coroutine[Any, Any, None], *, message: str) -> None:
    """Assert a wait stays pending — the only way to prove a poke did *not* fire."""
    try:
        await asyncio.wait_for(awaitable, timeout=0.05)
        raise AssertionError(message)
    except TimeoutError:
        pass


async def test_n_notifies_before_the_wake_collapse_into_one_poke() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()
    member_id = uuid.uuid4()

    with hub.subscribe(workspace_id, member_id) as subscription:
        for _ in range(5):
            hub.notify(workspace_id)

        await asyncio.wait_for(subscription.wait(), timeout=1)
        subscription.clear()

        # Five appends, one wake: the pull that follows sweeps up all of them.
        await _never_completes(
            subscription.wait(),
            message="a second poke was pending after the batch was consumed",
        )


async def test_notify_reaches_every_subscriber_of_the_workspace() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()
    member_id = uuid.uuid4()
    other_member_id = uuid.uuid4()

    with (
        hub.subscribe(workspace_id, member_id) as first,
        hub.subscribe(workspace_id, other_member_id) as second,
    ):
        hub.notify(workspace_id)

        await asyncio.wait_for(first.wait(), timeout=1)
        await asyncio.wait_for(second.wait(), timeout=1)


async def test_a_notify_never_crosses_workspaces() -> None:
    hub = SignalHub()
    mine = uuid.uuid4()
    theirs = uuid.uuid4()
    member_id = uuid.uuid4()

    with hub.subscribe(mine, member_id) as subscription:
        hub.notify(theirs)

        await _never_completes(subscription.wait(), message="a poke leaked across workspaces")


async def test_unsubscribe_drops_the_handle_and_the_workspace_entry() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()
    member_id = uuid.uuid4()

    subscription = hub.subscribe(workspace_id, member_id)
    assert hub.subscriber_count(workspace_id) == 1
    subscription.unsubscribe()
    assert hub.subscriber_count(workspace_id) == 0

    # Nothing is held after the last subscriber leaves, and notifying an empty
    # workspace is a no-op rather than an error.
    hub.notify(workspace_id)


async def test_revoke_trips_only_the_named_members_subscriptions() -> None:
    """A revocation reaches one Member's sockets and leaves everyone else's up.

    Without the member scoping the choice would be between closing every socket
    in the Workspace on any revocation, or closing none — and the second is what
    lets a revoked subscriber keep learning that activity exists.
    """
    hub = SignalHub()
    workspace_id = uuid.uuid4()
    revoked_member_id = uuid.uuid4()
    other_member_id = uuid.uuid4()

    with (
        hub.subscribe(workspace_id, revoked_member_id) as doomed,
        hub.subscribe(workspace_id, revoked_member_id) as also_doomed,
        hub.subscribe(workspace_id, other_member_id) as bystander,
    ):
        assert hub.revoke(workspace_id, revoked_member_id) == 2

        await asyncio.wait_for(doomed.wait_revoked(), timeout=1)
        await asyncio.wait_for(also_doomed.wait_revoked(), timeout=1)
        assert doomed.is_revoked()
        await _never_completes(
            bystander.wait_revoked(),
            message="a revocation closed a socket belonging to another Member",
        )


async def test_revoke_never_crosses_workspaces_and_is_a_no_op_when_unheld() -> None:
    hub = SignalHub()
    mine = uuid.uuid4()
    theirs = uuid.uuid4()
    member_id = uuid.uuid4()

    with hub.subscribe(mine, member_id) as subscription:
        # The same Member may hold a Grant in one Workspace and not another, so a
        # revocation is scoped to the pair rather than to the member alone.
        assert hub.revoke(theirs, member_id) == 0
        await _never_completes(
            subscription.wait_revoked(),
            message="a revocation leaked across workspaces",
        )

    assert hub.revoke(mine, member_id) == 0


async def test_a_revocation_is_not_a_poke_and_a_poke_is_not_a_revocation() -> None:
    """Two events, deliberately separate: one says *pull*, the other says *stop*."""
    hub = SignalHub()
    workspace_id = uuid.uuid4()
    member_id = uuid.uuid4()

    with hub.subscribe(workspace_id, member_id) as subscription:
        hub.notify(workspace_id)
        await asyncio.wait_for(subscription.wait(), timeout=1)
        await _never_completes(subscription.wait_revoked(), message="a poke read as a revocation")

        subscription.clear()
        hub.revoke(workspace_id, member_id)
        await asyncio.wait_for(subscription.wait_revoked(), timeout=1)
        await _never_completes(subscription.wait(), message="a revocation read as a poke")
