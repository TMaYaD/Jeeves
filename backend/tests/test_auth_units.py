"""Unit tests for auth utilities — hashing and token creation/decoding."""

import os

os.environ.setdefault("JEEVES_SECRET_KEY", "test-secret-key")

from jose import jwt

from app.auth.hashing import hash_password, verify_password
from app.auth.tokens import create_access_token
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
