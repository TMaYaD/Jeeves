"""In-process fan-out for the payload-free "new seq available" signal.

A poke means exactly one thing — *run a sync from your cursor now* — so the hub
never has to remember what it told whom.  Each subscriber owns one
``asyncio.Event``; ``notify`` sets it.  Event semantics give coalescing for
free: N notifies before the waiter wakes collapse into one poke, and the pull
that follows sweeps up everything past the cursor.  Nothing here is persisted,
no seq is stored, and no per-member cursor exists (review F17).

**Deployment constraint.** This fan-out is in-process, which is correct only
because uvicorn runs single-process everywhere we deploy (Dockerfile, Procfile,
compose — no ``--workers``).  A second worker would silently deliver pokes to
whichever process happens to own the writer's connection.  This class is the
seam where a Redis pub/sub implementation slots in (redis is already a
dependency), and that swap is the precondition for adding workers — see
``docs/BACKEND_GUIDELINES.md`` §6 and §8, which carry the same qualification.
"""

from __future__ import annotations

import asyncio
import uuid
from types import TracebackType


class SignalSubscription:
    """One subscriber's handle: an event that is set whenever news arrives.

    Used as an async context manager so the unsubscribe happens on every exit
    path, including a client disconnect raised out of the send loop.
    """

    def __init__(self, hub: SignalHub, workspace_id: uuid.UUID) -> None:
        self._hub = hub
        self._workspace_id = workspace_id
        self._event = asyncio.Event()

    async def wait(self) -> None:
        await self._event.wait()

    def pending(self) -> bool:
        """Whether a poke is waiting — the state ``wait`` would return on at once.

        The counterpart of ``subscriber_count``: it exists so a test can observe
        the fan-out without a socket, which is the only way a caller invoked
        outside the ASGI app can assert that a poke fired.
        """
        return self._event.is_set()

    def clear(self) -> None:
        self._event.clear()

    def notify(self) -> None:
        self._event.set()

    def unsubscribe(self) -> None:
        self._hub.unsubscribe(self._workspace_id, self)

    def __enter__(self) -> SignalSubscription:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.unsubscribe()


class SignalHub:
    def __init__(self) -> None:
        self._subscribers: dict[uuid.UUID, set[SignalSubscription]] = {}

    def subscribe(self, workspace_id: uuid.UUID) -> SignalSubscription:
        subscription = SignalSubscription(self, workspace_id)
        self._subscribers.setdefault(workspace_id, set()).add(subscription)
        return subscription

    def unsubscribe(self, workspace_id: uuid.UUID, subscription: SignalSubscription) -> None:
        holders = self._subscribers.get(workspace_id)
        if holders is None:
            return
        holders.discard(subscription)
        if not holders:
            del self._subscribers[workspace_id]

    def notify(self, workspace_id: uuid.UUID) -> None:
        """Poke every subscriber of this Workspace.  Never crosses Workspaces."""
        for subscription in tuple(self._subscribers.get(workspace_id, ())):
            subscription.notify()

    def subscriber_count(self, workspace_id: uuid.UUID) -> int:
        return len(self._subscribers.get(workspace_id, ()))


_hub = SignalHub()


def get_signal_hub() -> SignalHub:
    """FastAPI dependency, so a test can substitute or inspect the hub."""
    return _hub
