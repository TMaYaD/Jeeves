"""Unit tests for auth utilities — hashing and token creation/decoding."""

import hashlib
import os

import pytest

os.environ.setdefault("SECRET_KEY", "test-secret-key")

import jwt

from app.auth.hashing import hash_password, verify_password
from app.auth.tokens import create_access_token, create_refresh_token, hash_refresh_token
from app.config import settings


class TestPasswordHashing:
    def test_hash_and_verify_roundtrip(self) -> None:
        hashed = hash_password("my-secure-password")
        assert verify_password("my-secure-password", hashed)

    def test_wrong_password_fails(self) -> None:
        hashed = hash_password("correct")
        assert not verify_password("incorrect", hashed)

    def test_different_hashes_for_same_password(self) -> None:
        h1 = hash_password("same")
        h2 = hash_password("same")
        assert h1 != h2  # bcrypt salts differ


class TestAccessToken:
    def test_token_contains_subject(self) -> None:
        token = create_access_token({"sub": "user-123"})
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        assert payload["sub"] == "user-123"

    def test_token_contains_expiration(self) -> None:
        token = create_access_token({"sub": "user-123"})
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        assert "exp" in payload

    def test_token_preserves_extra_claims(self) -> None:
        token = create_access_token({"sub": "user-123", "role": "admin"})
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        assert payload["role"] == "admin"

    def test_access_token_expires_in_15_minutes(self) -> None:
        from datetime import UTC, datetime

        token = create_access_token({"sub": "user-123"})
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        exp = datetime.fromtimestamp(payload["exp"], tz=UTC)
        iat = datetime.fromtimestamp(payload["iat"], tz=UTC)
        delta_minutes = (exp - iat).total_seconds() / 60
        assert delta_minutes == pytest.approx(15, abs=1)


class TestRefreshToken:
    def test_raw_token_is_not_stored(self) -> None:
        raw, record = create_refresh_token("user-abc")
        assert raw not in record.token_hash

    def test_token_hash_is_sha256_of_raw(self) -> None:
        raw, record = create_refresh_token("user-abc")
        expected = hashlib.sha256(raw.encode()).hexdigest()
        assert record.token_hash == expected

    def test_hash_refresh_token_matches_stored_hash(self) -> None:
        raw, record = create_refresh_token("user-abc")
        assert hash_refresh_token(raw) == record.token_hash

    def test_different_raws_for_same_user(self) -> None:
        raw1, _ = create_refresh_token("user-abc")
        raw2, _ = create_refresh_token("user-abc")
        assert raw1 != raw2

    def test_expires_at_is_one_year_from_now(self) -> None:
        from datetime import UTC, datetime

        raw, record = create_refresh_token("user-abc")
        now = datetime.now(UTC)
        delta_days = (record.expires_at - now).days
        assert 364 <= delta_days <= 366

    def test_user_id_set_correctly(self) -> None:
        _, record = create_refresh_token("my-user-id")
        assert record.user_id == "my-user-id"
