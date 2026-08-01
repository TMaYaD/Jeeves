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
- **Application:** PostgreSQL and Redis are treated as external resources. The backend can swap them out by simply changing environment variables without requiring code changes.

### 5. Build, Release, Run
- **Principle:** Strictly separate build and run stages.
- **Application:** Docker images are built as a distinct artifact, tagged, and then released for running. Deployments are separate from the build process.

### 6. Processes
- **Principle:** Execute the app as one or more stateless processes.
- **Application:** The FastAPI process — the only process type there is — is entirely stateless, with one deliberate exception: `app/sync/signal_hub.py` holds live signal-socket subscriptions in process memory. Nothing there is persistent — it is a set of connected sockets, which cannot be offloaded anywhere — but it does mean a poke reaches only subscribers attached to the process that handled the write. See §8 for the constraint that follows.

### 7. Port Binding
- **Principle:** Export services via port binding.
- **Application:** Our FastAPI service uses `uvicorn` to bind to a port (usually 8000) and expose its HTTP API directly.

### 8. Concurrency
- **Principle:** Scale out via the process model.
- **Application:** We scale HTTP traffic by adding more Uvicorn workers or horizontally scaling the FastAPI containers. There is no background-job process type to scale — the server appends and serves op envelopes and does nothing asynchronously. **Precondition:** the op-log signal socket's in-process fan-out (§6) is correct only while uvicorn runs single-process, as it does in every deployment today (Dockerfile, Procfile, compose — no `--workers`). Replacing `SignalHub` with a Redis pub/sub implementation — the seam is that class, and redis is already a dependency — comes before the first extra worker, or realtime sync silently stops working for everyone not sharing a process with the writer.

### 9. Disposability
- **Principle:** Maximize robustness with fast startup and graceful shutdown.
- **Application:** Containers are designed to start quickly. They handle SIGTERM signals gracefully to drain connections and finish processing requests before shutting down.

### 10. Dev/Prod Parity
- **Principle:** Keep development, staging, and production as similar as possible.
- **Application:** We use `infra/` (Docker Compose) to run the exact same PostgreSQL and Redis infrastructure locally that we use in production.
- **Image pins:** every image reference — `backend/Dockerfile`, `infra/docker-compose.yml`, and the Postgres service in `.github/workflows/backend-ci.yml` — carries both the exact upstream version in the tag and the `@sha256:` digest (ADR-0045). The digest is what resolves and what makes the pull immutable; the tag states which version those bytes are, so a dependency bump is readable as a version change rather than a hex swap. Read the files for the values; this document deliberately does not restate them. Dependabot rewrites both halves together for the Dockerfile and the compose file, but does not read workflow service images — the CI Postgres pin is bumped by hand, and is held byte-identical to the compose one so CI tests against the image local dev runs.

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
- **Application:** Database migrations and administrative scripts are run as isolated one-off commands against a release within the same environment as the long-running processes. Migrations go through `python -m app.migrate` (`backend/app/migrate.py`) — a wrapper around `alembic upgrade head` that detects schema/version drift and fails with an actionable diagnostic instead of an opaque duplicate-object crash-loop. It never auto-stamps the version table (ADR-0012); recovery steps live in `infra/README.md` ("Recovering from schema/version drift").
- **Production:** `backend/Procfile` declares `release: python -m app.migrate`. Dokku runs this in a one-off container after each successful build and only promotes the new image to web traffic if the migration exits cleanly — so a failed migration aborts the deploy and prod stays on the previous release.
- **Local dev exception:** `infra/docker-compose.yml` runs `python -m app.migrate` inline before `uvicorn` for convenience. This is acceptable only for single-instance local dev. An advisory lock in `backend/alembic/env.py` prevents concurrent migration races.

## Server versioning & releases

The server is versioned independently of the Flutter app. App releases (`docs/RELEASES.md`) neither produce nor consume a server version, and the two live in separate tag namespaces that no pipeline crosses: the app's tag patterns cannot match a server tag, and the server's tag filter cannot match an app tag.

**The scheme is ordinary SemVer behind a `0.` prefix.** A reader sees `0.X.Y`, and `0.X.Y.Z` once an inner patch exists — X, Y and Z are the inner major, minor and patch, and the fourth segment is elided while the inner patch is zero. A breaking change bumps X, a feature bumps Y, a fix bumps Z. The project is pre-1.0 as a whole and the leading `0.` says so; the arithmetic underneath it is plain SemVer.

**Bumps are computed from the commits since the last server tag that touch the backend.** `infra/ci/compute-server-version.sh` is the single source of truth for the scheme: the tag prefix, the path filter and the classification rules are constants and code at the top of that script, and this document deliberately does not restate them. Read it for the values; read this section for why they are shaped the way they are.

Three things about the classification are worth knowing before reading the script:

- **App-only ranges produce no server version at all.** That is the entire point of the path filter, and it is a finer test than the deploy pipeline's own change detection — a commit range can trigger a defensive deploy and still cut no release.
- **There is a patch floor.** A range whose backend commits are all `chore`/`refactor`/`test`/dependency bumps — no `feat`, no `fix`, no breaking marker — still bumps the inner patch. Such a range ships different code, and without the floor it would deploy under an unchanged version and a `/health` that lies. "No bump" is reserved exclusively for a range with zero backend-touching commits.
- **Merge commits usually vanish, but not always.** The walk uses git's default history simplification, so the constituent commits of a merged PR classify normally while the `Merge pull request #N` commit is TREESAME to the merged branch and drops out. A merge that is TREESAME to *neither* parent — a conflict resolution that itself changes the backend — survives, and its non-conventional subject lands in the release notes' **Other** group. Seeing a merge subject there is expected, not a bug; the bump arithmetic is unaffected, because Other already carries the patch floor.

**Tags are cut by Backend CD**, in `.github/workflows/backend-cd.yml`, which is also the authority on *when*: what gates a run, and the order of tagging relative to the Dokku push. Tagging happens before the deploy, because the version names the release cut — a property of the commit — while `/health` is what reports deployed reality. The release is created through the GitHub API, which creates the tag as a side effect; the release notes are the same commit walk that decided the bump, grouped as Breaking / Features / Fixes / Other.

**The running server learns its version from the environment.** Dokku builds from a git archive with no `.git`, so the process cannot derive its own version; CD sets `SERVER_VERSION` on the app before every backend push, unconditionally rather than only when a tag was cut, so a defensive or re-run deploy converges onto the version the tags claim. `Settings.server_version` reads it, `/health` returns it, and the OpenAPI document carries it. Because those two publish the value verbatim, settings construction rejects anything that is not version-shaped — three or four numeric segments with an optional prerelease suffix, which is the shape the scheme above produces — so bad deployment metadata fails startup instead of becoming the version the server claims. Note this is deliberately *not* strict SemVer: the four-segment inner-patch form would fail a textbook `X.Y.Z` validator. The default, `0.0.0-dev`, names a local or otherwise un-deployed build honestly instead of claiming a release. A hand-rolled `git push dokku` bypasses the injection and will run new code under the previous version — use the pipeline.

`backend/pyproject.toml`'s `version` is **not** the server version and is not kept in step with it. Nothing consumes the wheel's version, and a second copy of the number would only drift.

### Seeding the baseline

The computation is a range since the last server tag, so the tag namespace has to be non-empty. If it is empty the script exits non-zero and prints the tag to create — a forgotten seed stops the pipeline rather than letting a deploy be labelled with a plausible guess. Seeding is a one-time manual step: push the baseline tag at `main`'s tip, and set `SERVER_VERSION` to the same value on the Dokku app so the already-running server reports its true baseline rather than the `0.0.0-dev` default until the next deploy.
