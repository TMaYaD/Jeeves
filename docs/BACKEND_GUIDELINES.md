# Backend Guidelines

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document outlines the architectural and engineering guidelines specific to the Jeeves backend service.

## 12-Factor App Methodology

The Jeeves FastAPI service is built following the [12-Factor App methodology](https://12factor.net/). This ensures that our backend is scalable, portable, and resilient.

### 1. Codebase
- **Principle:** One codebase tracked in revision control, many deploys.
- **Application:** The backend resides in the `backend/` directory of our mono-repo. The same codebase is deployed across all environments (local, staging, production).

### 2. Dependencies
- **Principle:** Explicitly declare and isolate dependencies.
- **Application:** We use explicit dependency management (e.g., `requirements.txt` or `pyproject.toml`) and execute inside isolated environments (like Docker containers and Python virtual environments).

### 3. Config
- **Principle:** Store config in the environment.
- **Application:** All configuration (database URLs, API keys, feature flags) is passed via environment variables (often loaded via `.env` files locally using `pydantic-settings`). We do not store secrets in source code.

### 4. Backing Services
- **Principle:** Treat backing services as attached resources.
- **Application:** PostgreSQL, Redis, and Anthropic API are treated as external resources. The backend can swap them out by simply changing environment variables without requiring code changes.

### 5. Build, Release, Run
- **Principle:** Strictly separate build and run stages.
- **Application:** Docker images are built as a distinct artifact, tagged, and then released for running. Deployments are separate from the build process.

### 6. Processes
- **Principle:** Execute the app as one or more stateless processes.
- **Application:** The FastAPI and Celery processes are entirely stateless. Any persistent state (sessions, cache, long-term data) is offloaded to PostgreSQL or Redis.

### 7. Port Binding
- **Principle:** Export services via port binding.
- **Application:** Our FastAPI service uses `uvicorn` to bind to a port (usually 8000) and expose its HTTP API directly.

### 8. Concurrency
- **Principle:** Scale out via the process model.
- **Application:** We scale HTTP traffic by adding more Uvicorn workers or horizontally scaling the FastAPI containers. We scale background jobs by adding Celery workers.

### 9. Disposability
- **Principle:** Maximize robustness with fast startup and graceful shutdown.
- **Application:** Containers are designed to start quickly. They handle SIGTERM signals gracefully to drain connections and finish processing requests before shutting down.

### 10. Dev/Prod Parity
- **Principle:** Keep development, staging, and production as similar as possible.
- **Application:** We use `infra/` (Docker Compose) to run the exact same PostgreSQL and Redis infrastructure locally that we use in production.

### 11. Logs
- **Principle:** Treat logs as event streams.
- **Application:** The application logs to standard output/error (stdout/stderr). Log routing and storage are handled by the infrastructure layer, not the application itself.

## Auth Provider Contract

All authentication endpoints return the same `Token` response shape:

```json
{"access_token": "...", "refresh_token": "...", "token_type": "bearer"}
```

Existing password-based endpoints (`POST /session`, `POST /user`) are unchanged.  SWS adds two new endpoints under `/auth/sws/`:

| Endpoint | Method | Description |
|---|---|---|
| `/auth/sws/challenge` | POST | Issue a single-use Redis-backed nonce for a Solana public key |
| `/auth/sws` | POST | Verify the ed25519 SIWS signature and return `Token` |

### SWS verification

1. **GETDEL nonce** — nonces are stored as `sws_nonce:{nonce}` in Redis with a 300-second TTL.  `GETDEL` is atomic: first use returns the stored data, second use returns `nil`, preventing replay.
2. **Reconstruct the SIWS message** — the exact message format (defined in `SIWS_TEMPLATE` in `sws_strategy.py`) must match the Flutter client byte-for-byte.
3. **Verify ed25519** — PyNaCl `VerifyKey` validates the signature; any failure raises HTTP 401.
4. **Upsert user** — users are identified by `solana_public_key` (base58).  A new `User` row is created on first sign-in; subsequent sign-ins reuse the existing row.

### User model invariants

- Password users: `email` non-null, `hashed_password` non-null, `solana_public_key` null.
- SWS users: `solana_public_key` non-null, `email` nullable, `hashed_password` nullable.
- Both fields are nullable at the DB layer (migration 0010) to support mixed deployments.

### 12. Admin Processes
- **Principle:** Run admin/management tasks as one-off processes.
- **Application:** Database migrations (`alembic upgrade`) and administrative scripts are run as isolated one-off commands against a release within the same environment as the long-running processes.
- **Production:** `backend/Procfile` declares `release: alembic upgrade head`. Dokku runs this in a one-off container after each successful build and only promotes the new image to web traffic if the migration exits cleanly — so a failed migration aborts the deploy and prod stays on the previous release.
- **Local dev exception:** `infra/docker-compose.yml` runs `alembic upgrade head` inline before `uvicorn` for convenience. This is acceptable only for single-instance local dev. An advisory lock in `backend/alembic/env.py` prevents concurrent migration races.
