"""The fan-out primitive, away from any socket.

Everything the signal protocol promises about coalescing and Workspace
isolation is a property of this class; the socket tests then prove the route
uses it as advertised.
"""

from __future__ import annotations

import asyncio
import uuid

from app.sync.signal_hub import SignalHub


async def test_n_notifies_before_the_wake_collapse_into_one_poke() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()

    with hub.subscribe(workspace_id) as subscription:
        for _ in range(5):
            hub.notify(workspace_id)

        await asyncio.wait_for(subscription.wait(), timeout=1)
        subscription.clear()

        # Five appends, one wake: the pull that follows sweeps up all of them.
        with_timeout = asyncio.wait_for(subscription.wait(), timeout=0.05)
        try:
            await with_timeout
            raise AssertionError("a second poke was pending after the batch was consumed")
        except TimeoutError:
            pass


async def test_notify_reaches_every_subscriber_of_the_workspace() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()

    with hub.subscribe(workspace_id) as first, hub.subscribe(workspace_id) as second:
        hub.notify(workspace_id)

        await asyncio.wait_for(first.wait(), timeout=1)
        await asyncio.wait_for(second.wait(), timeout=1)


async def test_a_notify_never_crosses_workspaces() -> None:
    hub = SignalHub()
    mine = uuid.uuid4()
    theirs = uuid.uuid4()

    with hub.subscribe(mine) as subscription:
        hub.notify(theirs)

        try:
            await asyncio.wait_for(subscription.wait(), timeout=0.05)
            raise AssertionError("a poke leaked across workspaces")
        except TimeoutError:
            pass


async def test_unsubscribe_drops_the_handle_and_the_workspace_entry() -> None:
    hub = SignalHub()
    workspace_id = uuid.uuid4()

    subscription = hub.subscribe(workspace_id)
    assert hub.subscriber_count(workspace_id) == 1
    subscription.unsubscribe()
    assert hub.subscriber_count(workspace_id) == 0

    # Nothing is held after the last subscriber leaves, and notifying an empty
    # workspace is a no-op rather than an error.
    hub.notify(workspace_id)
