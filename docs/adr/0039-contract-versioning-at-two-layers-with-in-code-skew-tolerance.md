# ADR-0039: The contract is versioned at two layers, and skew is tolerated in code

**Status:** Accepted (#518). Constrains #580 and #627.

## Context

Client/backend skew is permanent, not a deploy window: a Device in a pocket can
be arbitrarily old and may never be updated. Nothing in the code tolerates it
today. `backend/app/main.py:39-41` mounts the health, auth and sync routers with
no prefix at all, so neither side can state or honour a contract version; the
only version on the wire is the deploy label `GET /health` reports
(`backend/app/health/routes.py:10-14`, ADR-0029), and no Dart code reads it.
Every sync request model in `backend/app/sync/schemas.py` — `PostOpsRequest` at
`:82`, `PutKeyWrapsRequest` at `:123`, `MemberRegisterRequest` at `:14` — relies
on Pydantic v2's default `extra='ignore'`, so a backend older than the client
accepts a write, discards the field it does not know, and answers `200`.

Skew *is* discovered, but only per-op and only by convention: fail-closed served
sets for the suite byte and op class, hand-mirrored in two languages
(`backend/app/sync/envelope.py:87,99-113` against
`app/lib/sync/envelope.dart:78,92-106`), served control types, and the stance
that "the domain string is the version" — every field addition ships under a new
signing domain so a downgrade is a signature failure rather than a parsing
ambiguity (`backend/app/sync/control_payload.py:54-57`). Two reader paths
undercut that. The client folds every refusal code it does not recognise into a
generic transport failure (`app/lib/sync/http_sync_transport.dart:383`), so a new
server refusal is indistinguishable from any other error of the same status. And
the projector skips an unknown collection and an unknown field with no
Quarantine row, no Integrity Alarm and no counter
(`app/lib/sync/domain_projector.dart:67`, `:129`) — the op is durably reduced, so
nothing is lost, but an older build looks like it is working and is quietly
incomplete.

## Decision

**`main` stays deployable, and skew is handled in code — never by controlling
deploy order.** No sequencing rule, staging window or minimum-supported-version
gate is an acceptable substitute, because none of them reaches the old build in
someone's pocket. What ships is a contract that both halves can name and readers
that fail loudly rather than quietly.

**There are two contract layers, and they get different mechanisms.** The
server-visible surface — auth, Member, KeyWrap, epoch, recovery, and the op
transport routes, plus the two op classes the server does read (control ops per
ADR-0028, Prune ops per ADR-0038) — carries an explicit contract version on the
route path, and a representation change on it is mapped once, server-side.
Unknown fields on that surface become a refusal rather than a silent drop: this
is the stance the codebase already takes one layer down, where `tombstone_hlc`
outside its op class is refused precisely because "a permitted-and-ignored field
is one a future reader may start honouring"
(`backend/app/sync/op_payload.py:86-94`), extended to the HTTP boundary where
today it does not hold.

**The op payload cannot be versioned that way and must not pretend to be.** A
URL prefix versions the framing of `GET /w/{workspace_id}/ops`, not the
representation inside an envelope the server is forbidden to read (ADR-0026;
`backend/app/sync/op_payload.py:3-7` — no route imports the payload codec) and
could not rewrite if it were allowed to, because the envelope is
signature-covered. Payload representation is therefore versioned **in band**, by
the mechanism already in the tree: a new signing domain, suite byte or op class,
admitted through the served sets, with the shape pinned by the golden vectors in
`spec/sync/` that both the Dart and the Python runner assert. Those vectors are
the single normative definition of a representation. That is what "translate
once, not per client" means on a read path with no server able to do the
translating — one cross-language definition, not per-client handling — and it is
the honest answer to the fact that the read path has no prefix to version.

**A reader that meets a version it does not serve refuses under a named code and
keeps the bytes; it never accepts and discards.** Refusal codes are protocol
surface, not an implementation detail (ADR-0032), so a code a reader does not
recognise is surfaced verbatim in the Quarantine row rather than folded into
another code's meaning, and a deterministic refusal is terminalised rather than
retried as though it were transient. Retirement runs additive-first: the new
shape ships, older readers refuse-and-keep it, and the old shape is removed only
when no reader in the field can still produce it.

## Trade-off

**Two mechanisms is the cost, and the in-band one is expensive.** A payload
representation change means a new signing domain, freshly frozen vectors on both
runners, and served-set edits in two languages — deliberately more friction than
a URL bump. It is accepted because the cheap alternative is a server that reads
content, which is exactly what ADR-0026 spent a rewrite to stop doing.

**Turning `extra='ignore'` into a refusal makes the contract version
load-bearing from the first deploy.** An accidental extra field becomes a hard
failure instead of a shrug, and every client-side request builder is now
something a stale backend can reject outright. That is the point — the failure it
replaces is a `200` that lost a column — but it removes the slack the current
default silently provides, and it is why the version must land in the same change
as the policy rather than after it.

Minimum-supported-version gating and update prompting stay out of scope (#518),
so the defined behaviour for "backend older than this client" is refuse and
surface, not upgrade-and-continue. Two open issues inherit directly. **#580** —
the `cert_root_pk_mismatch` collapse — is settled toward aligning: a client that
can only say `bad_root_signature` destroys information a skewed Device cannot
recover, and under this decision a code is shared vocabulary pinned by vectors on
both runners rather than something either half may narrow locally. **#627** — an
epoch that can provably never publish — is the terminalisation rule made
concrete: `keywrap_digest_mismatch` on a resume PUT is deterministic, so it must
become a named Integrity Alarm and a terminal record rather than a refusal
re-attempted on every pull for ever.
