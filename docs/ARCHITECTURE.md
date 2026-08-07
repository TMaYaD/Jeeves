# Architecture

A map of the system at 20,000 ft: the regions, and the roads between them. It is
not a reproduction of the codebase — for how anything works, read the code. This
tells you which code to open.

For what the words mean, see [CONTEXT.md](../CONTEXT.md). For why a decision went
the way it did, see [docs/adr/](adr/). For how it came to be, `git blame`, the PR
and the issue.

## The system in one page

Jeeves is an offline-first GTD app. A Flutter client owns the data and does all
the thinking; a Python server stores and forwards signed, opaque envelopes and
never interprets them.

Local writes land in an embedded SQLite store immediately and are replicated
between a user's devices by an append-only **op log** per Workspace
([ADR-0026](adr/0026-minimal-sync-server.md)). The network is never in the write
path. A device that has never seen the server is fully functional, and staying
that way is a correctness requirement rather than a nicety
([ADR-0040](adr/0040-local-durability-is-independent-of-sync.md)).

The fleet is one Android phone. Web and desktop targets compile — that is the
bar — but carry no storage adapter.

```text
jeeves/
├── app/          # Flutter client — the whole domain lives here
├── backend/      # FastAPI service — the minimal sync server, nothing else
├── spec/         # Frozen golden vectors, shared by both test suites
├── infra/        # Compose stack and the local developer environment
├── tools/        # Repo-level scripts
└── docs/         # This map, the design docs, and docs/adr/
```

## Standing principles

- **Flat and explicit** over deep abstraction. Group by feature, not by layer.
- **The client is the source of truth.** The server holds no domain schema, no
  domain routes, and no opinion about what an envelope contains.
- **Sync is not a correctness dependency.** Local durability stands alone; the
  server is never a recovery path.
- **Test real behaviour.** No mocks for system components. If a thing cannot be
  tested as it runs in production, redesign it — see [TESTING.md](TESTING.md).

## The client: the road from screen to store

Five layers, and a write crosses all of them in one direction.

| Layer | Directory | What lives here |
|---|---|---|
| Screens | `app/lib/screens/` | One directory per surface; routing in `router.dart` |
| Widgets | `app/lib/widgets/` | Shared components — the title bar, the ceremony shell, the action bars |
| Providers | `app/lib/providers/` | Riverpod state. The only thing screens talk to |
| Services | `app/lib/services/` | Multi-DAO orchestration that is not a single write |
| DAOs | `app/lib/database/daos/` | Every read and every write, in Drift |

A screen never touches a DAO. Providers hold state and are the seam tests drive.
Services exist only where an operation spans several DAOs and has to be
atomic — clarification is the standard example. Domain models are `freezed`
classes in `app/lib/models/`.

**Writes describe themselves.** Every DAO write runs inside a *capturing scope*
(`GtdDatabase.capturing`), which is one transaction and which hands the effect to
the capture seam so it can become an op. This is the single most important
invariant in the client: a domain write that escapes a capturing scope is a write
that never reaches another device.

**Reads are streams.** Surfaces watch Drift queries and rebuild when the tables
they name change. A write that mutates a table its own query does not name must
notify explicitly, or the surface will not refresh.

## Two stores

Every device holds two SQLite files, deliberately not one.

- **`jeeves_domain.sqlite`** — the domain read model, over `sqlite_async`. This
  is what the app reads. It is *derived*: a device can throw it away and
  reproject it from its own op log.
- **`jeeves_sync.sqlite`** — the op log, the outbox, the quarantine, the
  integrity alarms and the control chain, over Drift's native executor on a
  background isolate so reducing a page of ops never competes for frames. This
  is the record. It is not disposable, and nothing may treat it as if it were.

Two files rather than two schemas in one file, so that an operation whose whole
premise is that the read model can be discarded cannot take the evidence with it.

## The sync spine

`app/lib/sync/` is the largest region in the client and has its own map:
**[SYNC.md](SYNC.md)**. In outline:

Ops are signed, per-author-chained envelopes appended to a per-Workspace log. A
**reducer** merges them field-by-field under a per-field clock, so replaying a log
from zero yields byte-identical state to a device that was online throughout —
every non-LWW merge strategy must therefore be a join-semilattice
([ADR-0030](adr/0030-merge-strategies-must-be-join-semilattices.md)). Membership
and key facts are themselves signed ops, chained to a passphrase-escrowed root
([ADR-0028](adr/0028-signed-control-plane-in-the-log.md)).

**Syncing starts at enrolment**, not at launch
([ADR-0034](adr/0034-sync-starts-at-enrolment.md)). Enrolment is opt-in and no
code path routes a user into it. Until the enrolment question is answered the
capture seam *buffers*, so a write on the first turn of a cold start is never
lost to the async chain — a decision disposes of a buffered op, never launch
timing.

Four pieces carry the domain across the spine, and the split between the last two
is load-bearing: the **capture seam** turns writes into ops; the **codecs** name
the synced columns and the one canonical value encoding; the **projector** turns
reduced state into rows and *authors nothing*; the **reconciler** takes the
convergence decisions the projector must not, because they have to reach peers
and so must author ops.

`spec/sync/` holds frozen golden vectors that both suites assert byte-equality
against. Regenerating them is a protocol change, not a chore.

## The server

`backend/` is the minimal sync server and nothing else: `app/auth`, `app/sync`,
`app/health`. It appends and serves opaque envelopes, indexes who exists and who
holds which grant, and stores passphrase-wrapped key material it can never open.

It reads the fixed-size envelope header for its index columns and its
content-blind authorization, and never a content body — with two deliberate,
permanently-plaintext exceptions where the server has to *act* on the payload:
control ops, so membership can be checked before it is materialised, and prune
ops, whose enumeration is transport positions and hashes the server already
holds.

Two credentials, resolved at one site: a **user** credential for account-level
routes, and a **member-scoped** token — issued only against a signature over a
device key — for everything Workspace-scoped, sockets included. Neither is
accepted where the other belongs, refresh tokens included, so a device cannot
launder its member token into a session that reaches the escrow.

Stack: FastAPI on `uvicorn`, SQLAlchemy with `asyncpg`, Alembic, Pydantic, Redis
for nonces and rate-limit counters. No task queue and no background workers.
Deployment is one Dokku app whose release phase runs Alembic; a failed migration
aborts the deploy. Conventions in [BACKEND_GUIDELINES.md](BACKEND_GUIDELINES.md).

## Ceremonies

Daily Planning, Focus execution, Evening Shutdown and the Weekly Review are one
shape, not four features. A **Ceremony** is a stepped performance with a
lifecycle — not-started, in-progress, terminated as either completed or
abandoned — driven by a shared wizard shell in `app/lib/widgets/ceremony/`, with
one provider per ceremony holding its state. The Nudge, Trigger and Cadence machinery is mapped in [CEREMONIES.md](CEREMONIES.md).

A **Ritual** is a Ceremony with a cadence overlay: a Trigger decides when its
**Nudge** surfaces. One hygiene rule is centralised at the Nudge level rather
than duplicated into each Trigger — while a performance of a Ritual is in
progress, none of its Nudges surface.

Sessions change state only by explicit user action and never auto-close
([ADR-0020](adr/0020-sessions-never-auto-close-anchor-day-attribution.md)); the
Plan is a commitment and never auto-grows
([ADR-0002](adr/0002-plan-as-commitment-not-auto-growing.md)). Both are why the
review step can be trusted to be the only thing that resolves a day.

The vocabulary — Capture, Outcome, Action, Plan, Disposition, Settled — is
defined in [CONTEXT.md](../CONTEXT.md) and is not repeated here.

## Extension seams

The places designed to be extended, and the contract each one carries.

| Seam | Where | Contract |
|---|---|---|
| Platform I/O | `*_stub.dart` / `*_io.dart` / `*_web.dart` + conditional export | Any file, process or native call. Never an `if (kIsWeb)` branch in provider or service code |
| Auth provider | `app/lib/auth/` | An abstract interface with compile-time mode selection; adding one means implementing the interface, not editing callers |
| Collection | `app/lib/sync/collection_codecs.dart` | A synced table names its columns and value encoding in one place |
| Merge strategy | `app/lib/sync/merge_strategy.dart` | A per-key registry; every non-LWW entry must be a join-semilattice |
| Device key store | `app/lib/sync/` | Keychain/Keystore in production, in-memory in the harness — the same closures run in both |

The platform-adapter rule is the one most easily broken by accident: three files
per adapter, and the entry point picks the implementation by conditional export.
The two store openers and the emulator detector are the current adapters; both
stores stub out on web and throw, which is honest rather than a gap.

## Where to go next

| Question | Document |
|---|---|
| What does this word mean? | [CONTEXT.md](../CONTEXT.md) |
| How does sync work in detail? | [SYNC.md](SYNC.md) |
| How do Nudges and Rituals fire? | [CEREMONIES.md](CEREMONIES.md) |
| Why is it like this? | [docs/adr/](adr/) |
| What are we building, and why that? | [REQUIREMENTS.md](REQUIREMENTS.md) |
| What should it look like? | [DESIGN.md](DESIGN.md) |
| How is it tested, and what bites? | [TESTING.md](TESTING.md) |
| Server conventions and deployment | [BACKEND_GUIDELINES.md](BACKEND_GUIDELINES.md) |
| What surprised a previous agent? | [NOTES.md](../NOTES.md) |
