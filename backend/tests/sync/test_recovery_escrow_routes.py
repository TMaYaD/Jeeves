"""The recovery escrow contract.

``app/test/sync/fake_sync_server_contract_test.dart`` mirrors this file, so the
harness's enrolment tests are evidence about the real server rather than about a
double that happens to agree with them.
"""

from __future__ import annotations

import base64
import uuid

from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.sync.escrow import RECOVERY_FETCH_DAILY_LIMIT
from app.sync.ids import default_workspace_id
from app.sync.models import RecoveryEscrow, RecoveryEscrowFetch
from tests.conftest import auth_header, register
from tests.sync.builders import SpecRoot, escrow_blob, user_id_from_token


class EscrowFixture:
    def __init__(self, token: str, workspace_id: uuid.UUID, root: SpecRoot) -> None:
        self.token = token
        self.workspace_id = workspace_id
        self.root = root

    @property
    def headers(self) -> dict[str, str]:
        return auth_header(self.token)


async def _open(client: AsyncClient, email: str) -> EscrowFixture:
    token = await register(client, email)
    return EscrowFixture(token, default_workspace_id(user_id_from_token(token)), SpecRoot())


def detail_of(response: object) -> dict[str, object]:
    detail = response.json()["detail"]  # type: ignore[attr-defined]
    assert isinstance(detail, dict), detail
    return detail


# --- PUT /w/{w}/recovery ------------------------------------------------------


async def test_the_first_write_establishes_the_root_key(
    client: AsyncClient, db: AsyncSession
) -> None:
    escrow = await _open(client, "escrow-create@example.com")
    body = escrow.root.escrow_body(escrow.workspace_id)
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery", json=body, headers=escrow.headers
    )
    assert response.status_code == 200, response.text

    stored = await db.get(RecoveryEscrow, (escrow.workspace_id, user_id_from_token(escrow.token)))
    assert stored is not None
    assert stored.version == 1
    assert stored.root_pk == escrow.root.root_pk
    assert base64.b64encode(stored.blob).decode("ascii") == body["blob_b64"]


async def test_a_create_at_any_other_version_is_a_regression(
    client: AsyncClient, db: AsyncSession
) -> None:
    """``stored_version: 0`` reads as "no record exists; create must be v1"."""
    escrow = await _open(client, "escrow-create-v7@example.com")
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id, version=7),
        headers=escrow.headers,
    )
    assert response.status_code == 409, response.text
    assert detail_of(response) == {"code": "escrow_version_regression", "stored_version": 0}
    assert (await db.execute(select(RecoveryEscrow))).scalars().all() == []


async def test_a_passphrase_change_bumps_the_version(client: AsyncClient) -> None:
    escrow = await _open(client, "escrow-rewrap@example.com")
    await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id),
        headers=escrow.headers,
    )
    rewrapped = escrow.root.escrow_body(escrow.workspace_id, version=2)
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery", json=rewrapped, headers=escrow.headers
    )
    assert response.status_code == 200, response.text
    assert response.json()["version"] == 2
    assert response.json()["blob_b64"] == rewrapped["blob_b64"]


async def test_the_older_blob_is_refused_after_a_rewrap(client: AsyncClient) -> None:
    """AC4: once the version has moved, the previous one cannot be re-planted."""
    escrow = await _open(client, "escrow-rollback@example.com")
    first = escrow.root.escrow_body(escrow.workspace_id)
    await client.put(f"/w/{escrow.workspace_id}/recovery", json=first, headers=escrow.headers)
    await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id, version=2),
        headers=escrow.headers,
    )

    replay = await client.put(
        f"/w/{escrow.workspace_id}/recovery", json=first, headers=escrow.headers
    )
    assert replay.status_code == 409, replay.text
    assert detail_of(replay) == {"code": "escrow_version_regression", "stored_version": 2}

    same_version = await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id, version=2),
        headers=escrow.headers,
    )
    assert same_version.status_code == 409, same_version.text


async def test_a_stolen_user_credential_cannot_overwrite_the_escrow(
    client: AsyncClient, db: AsyncSession
) -> None:
    """AC3/F16: the User credential reaches the slot; only Root gets into it."""
    escrow = await _open(client, "escrow-f16@example.com")
    await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id),
        headers=escrow.headers,
    )

    attacker_root = SpecRoot()
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=attacker_root.escrow_body(escrow.workspace_id, version=2),
        headers=escrow.headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "bad_escrow_signature"}

    stored = await db.get(RecoveryEscrow, (escrow.workspace_id, user_id_from_token(escrow.token)))
    assert stored is not None and stored.root_pk == escrow.root.root_pk


async def test_a_bad_root_signature_is_refused_on_the_first_write_too(
    client: AsyncClient,
) -> None:
    escrow = await _open(client, "escrow-bad-sig@example.com")
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id, corrupt_signature=True),
        headers=escrow.headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "bad_escrow_signature"}


async def test_a_blob_signed_for_another_workspace_cannot_be_replayed(
    client: AsyncClient,
) -> None:
    """The workspace id sits inside the signed preimage, so the slot is bound."""
    escrow = await _open(client, "escrow-slot-bound@example.com")
    foreign = escrow.root.escrow_body(default_workspace_id("somebody-else"))
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery", json=foreign, headers=escrow.headers
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "bad_escrow_signature"}


async def test_a_signature_for_another_version_does_not_transfer(
    client: AsyncClient,
) -> None:
    """The version is inside the preimage too, so a v1 signature is not a v2 one."""
    escrow = await _open(client, "escrow-version-bound@example.com")
    blob = escrow_blob()
    signed_for_v1 = escrow.root.escrow_body(escrow.workspace_id, version=1, blob=blob)
    response = await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json={**signed_for_v1, "version": 2},
        headers=escrow.headers,
    )
    assert response.status_code == 403, response.text


async def test_another_users_escrow_slot_is_unreachable(client: AsyncClient) -> None:
    mine = await _open(client, "escrow-mine@example.com")
    theirs = await _open(client, "escrow-theirs@example.com")
    write = await client.put(
        f"/w/{theirs.workspace_id}/recovery",
        json=mine.root.escrow_body(theirs.workspace_id),
        headers=mine.headers,
    )
    assert write.status_code == 403, write.text
    read = await client.get(f"/w/{theirs.workspace_id}/recovery", headers=mine.headers)
    assert read.status_code == 403, read.text


async def test_the_escrow_requires_authentication(client: AsyncClient) -> None:
    workspace_id = default_workspace_id("nobody")
    assert (await client.get(f"/w/{workspace_id}/recovery")).status_code == 401
    assert (await client.put(f"/w/{workspace_id}/recovery", json={})).status_code == 401


# --- GET /w/{w}/recovery ------------------------------------------------------


async def test_the_fetch_returns_the_record_verbatim_and_is_audited(
    client: AsyncClient, db: AsyncSession
) -> None:
    escrow = await _open(client, "escrow-fetch@example.com")
    written = escrow.root.escrow_body(escrow.workspace_id)
    await client.put(f"/w/{escrow.workspace_id}/recovery", json=written, headers=escrow.headers)

    response = await client.get(f"/w/{escrow.workspace_id}/recovery", headers=escrow.headers)
    assert response.status_code == 200, response.text
    assert response.json() == {
        "version": 1,
        "blob_b64": written["blob_b64"],
        "root_sig_b64": written["root_sig_b64"],
        "root_pk_b64": written["root_pk_b64"],
    }

    audited = (await db.execute(select(RecoveryEscrowFetch))).scalars().all()
    assert [row.user_id for row in audited] == [user_id_from_token(escrow.token)]


async def test_fetching_an_empty_slot_is_a_404(client: AsyncClient) -> None:
    escrow = await _open(client, "escrow-empty@example.com")
    response = await client.get(f"/w/{escrow.workspace_id}/recovery", headers=escrow.headers)
    assert response.status_code == 404, response.text
    assert detail_of(response) == {"code": "no_recovery_escrow"}


async def test_the_fetch_is_rate_limited(client: AsyncClient, db: AsyncSession) -> None:
    """A scripted exfiltration attempt becomes an alarm, not a quiet download."""
    escrow = await _open(client, "escrow-rate-limit@example.com")
    await client.put(
        f"/w/{escrow.workspace_id}/recovery",
        json=escrow.root.escrow_body(escrow.workspace_id),
        headers=escrow.headers,
    )

    for _ in range(RECOVERY_FETCH_DAILY_LIMIT):
        allowed = await client.get(f"/w/{escrow.workspace_id}/recovery", headers=escrow.headers)
        assert allowed.status_code == 200, allowed.text

    refused = await client.get(f"/w/{escrow.workspace_id}/recovery", headers=escrow.headers)
    assert refused.status_code == 429, refused.text
    detail = detail_of(refused)
    assert detail["code"] == "escrow_fetch_rate_limited"
    assert isinstance(detail["retry_after_seconds"], int)
    assert detail["retry_after_seconds"] > 0

    # The refused attempt is not audited: no bytes left the server.
    fetched = await db.execute(select(func.count()).select_from(RecoveryEscrowFetch))
    assert fetched.scalar_one() == RECOVERY_FETCH_DAILY_LIMIT
