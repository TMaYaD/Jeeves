# Proposal: Minimal Sync Server

**Status:** Design settled (grilled 2026-07-27, vocabulary in `CONTEXT.md`; adversarial security review adopted in full — see [Security review](./minimal-sync-server-security-review.md)). Not yet broken into issues.

**ADRs:** [0026 Minimal Sync Server](../adr/0026-minimal-sync-server.md) · [0027 Workspace as partition unit](../adr/0027-workspace-as-partition-unit.md) · [0028 Signed control plane in the log](../adr/0028-signed-control-plane-in-the-log.md) · [0025 Area is exclusive](../adr/0025-area-is-exclusive-label-is-cross-cutting.md)

**Supersedes (on landing):** the PowerSync replication architecture — the **Sync Shape**, **Bucket**, **BackendConnector**, **Dead Letter**, **Sync Token** machinery and the upload contracts in `docs/SYNC.md`. Reframes ADR-0011 and ADR-0015 as client-side concerns; retires ADR-0017. ADR-0025 (Area is exclusive) was decided during this design and stands on its own.

## Problem

The backend duplicates the entire domain schema — 13 mirrored tables, 29 Alembic migrations, ~700 lines of Pydantic schemas, ~1,400 lines of routes — to do exactly two jobs: move rows between devices, and hold them while devices are offline. Every PowerSync bucket definition is the same shape (`SELECT * FROM t WHERE user_id = bucket.user_id`); the server partitions on nothing but `user_id`, yet must understand every column to do it.

The mirror's real cost is the contract it forces. Most of `docs/SYNC.md` exists only because the server parses rows: column-ownership matrices, "every client-owned column must round-trip verbatim", the 4xx classification and dead-letter machinery, the create-dedupe/upsert-on-replay rules, the "add the column to both schemas and the tripwire test" ritual. Schema drift produces real bugs (#380's vanishing `clarified`). And the interesting engine behaviour is untestable: the Dart harness runs on plain SQLite with no PowerSync engine, so the delete-on-absent windows are verified only by hand.

Meanwhile the server-side smarts never did the smart part. Domain conflict resolution already lives on the client (the `user_preferences` Conflict Strategy registry, `convergeMultiCurrentActions`); ids are client-generated; replay is idempotent by client-declared ids. We pay for a smart server that acts as a minimal one — so make it one, and collect the payoff: end-to-end encryption becomes possible, the domain schema becomes a client-only concern, and sync becomes testable in-process (N simulated devices, fake clock, no engine dependency).

AI features become **clients, not server features**: a Service holds a key the User granted and reads the data like any device. There is no server-side AI. (The current `backend/app/ai/` is dead code — zero callers — and is pruned with the rest of the old backend.)

## Shape

The server stores and transports **opaque payloads**. It never parses domain rows and never changes when the domain model does. Opacity is contractual from day one and cryptographic from `aead_v1` on: the first cutover ships `plaintext_v1` envelopes (see Migration), so until E2EE turns on the server *could* read a payload it is contractually forbidden to parse; after it, the server holds no decryption capability at all. The confidentiality boundary therefore moves with that envelope swap, and only the `aead_v1` phase defends against a hostile operator or a stolen database.

Its irreducible knowledge: identity (Users, Members and their public keys), partition (Workspaces, Grants — wrapped keys it cannot unwrap), order (a per-Workspace sequence assigned at receipt), cursors' *absence* (see metadata), retention, a payload-free "there's news" signal, and quotas on ciphertext bytes.

```
users(id, ...)
members(id, user_id NULL, kind, ...)          -- Device: user_id NOT NULL; Service: NULL (registered, not owned)
member_keys(member_id, key_id, kind, pubkey, valid_from, valid_until)
workspaces(id, ...)                           -- opaque; no owner column: participation IS the Grants
ops(workspace_id, seq BIGSERIAL, envelope BYTEA, compacted_by NULL, ...index cols from header)
grants / keywraps / recovery                  -- materialised index of signed control ops; authoritative for nobody
```

`seq` is a transport cursor and nothing else — never causality, never conflict resolution, never evidence. `received_at` is never an input to merge. The server does not persist per-member cursors; `since=` is a client parameter.

## Transport: append-only op log per Workspace

- An **Op** carries changed fields, not row snapshots: `{collection, id, fields{}, hlc}` inside the ciphertext. Field-grain LWW by hybrid logical clock `(wall_ms, counter, member_id)` is the default merge; the per-key Conflict Strategy registry pattern survives as the client-side exception mechanism.
- **Deletion is an op** (tombstone), never row absence. The entire class of delete-on-absent reconciliation windows in `docs/SYNC.md` is structurally impossible.
- **The reducer tolerates references to entities it has never seen** — out-of-causal-order arrival is routine, and cross-Workspace references render as *elsewhere*, never as missing or corrupt.
- Reducer guards: quarantine ops whose `wall_ms` exceeds local time by more than ~5 minutes; reject ops whose `hlc` member id differs from the header's Author.
- Push: `POST /w/{w}/ops` (batch, idempotent by author-namespaced op id). Pull: `GET /w/{w}/ops?since=seq`. A socket signals "new seq available" with no payload.

## Workspace: the partition unit

A **Workspace** is a complete, isolated GTD system — own Inbox, own Areas, own Next List, own Plan — per Allen's office-desk/home-desk analogy, not a shard of one system. It is the unit of key, partition, ordering, and access grant. One per User today; designed for several. See the `CONTEXT.md` entry for the full rules; the ones that shape the protocol:

- **Area is exclusive (1:N) inside a Workspace** (ADR-0025); everything Area-less (Captures, Tags, FocusSessions, TimeLogs) sits directly in its Workspace. `user_preferences` is User-global: an implicit Workspace every Device is granted and no Service ever is — which also means a preference can never leak through an AI grant.
- **Isolation is storage + membership, not the User's view.** Devices hold every key their User holds and render across Workspaces (a day's Plan is a client-side union of per-Workspace FocusSessions). A Service holding one key resolves foreign references as *elsewhere*.
- **A Capture lands in the current Workspace, unprompted** — capture never asks a question. Relocation is a clarification verdict, mechanically copy + re-encrypt + sign + write + tombstone-source. Moving a clarified Outcome (with Action history and TimeLogs) is the same operation at higher cost, deliberately rare. Never an `UPDATE` of a partition column.
- **Delegation over co-ownership** for human collaboration: hand an Outcome to another User by copying it into *their* Workspace and keeping a PersonBlocker + Waiting For on the sender's side. A Workspace stays one mind's system; co-owned substrate/stance splitting is architecturally possible over cross-Workspace references but is not the direction.

## Identity and keys

The entity vocabulary is normative in `CONTEXT.md` (Implementation tier): **User** authenticates; **Member** holds keys (kinds: **Device** — owned by exactly one User; **Service** — registered, not owned, `user_id NULL`, identity key pinned in the app binary or by user-confirmed fingerprint, signing short-lived per-User KEX subkeys); **Grant** is the signed membership fact carrying a role; **KeyWrap** delivers the Workspace key for one epoch to one Member; **Root** is the User's passphrase-escrowed signing authority; **Recovery** is the escrow, not a participant; **Author** is a role on an op, not an entity.

- **Workspace key:** random 256-bit symmetric key per `(workspace, epoch)` — never derived. Rotation (on revocation, and quarterly on schedule) mints the next epoch and re-wraps for survivors; revoke+rotate is one atomic act with a `keywrap_digest` proving the wrap-set is complete. An orphaned grant (Grant without current-epoch KeyWrap) is a nameable, surfaced state.
- **Roles → allowed op classes** (enforced content-blind via the cleartext `op_class`):

| Role | May emit | Trust |
|---|---|---|
| owner | content + control (grants, revocations, promotions) | full |
| participant | content | full read/write |
| compactor | compaction + prune | **most-trusted** (full read + history re-assertion) |
| suggester | suggestions only | least-trusted; **the AI Service's default** |

- **Enrolment:** a new Device needs only the passphrase — unwrap Recovery, obtain Root, generate keypairs, self-register via a Root-signed control op. No second device online, ever. Passphrase: user-chosen with a generated diceware default; the override path shows a strength estimate and explicit warning (passphrase entropy is the E2EE ceiling against a stolen-ciphertext adversary).
- **Transport auth:** member-scoped JWTs issued on proof-of-possession of the member signing key (domain-separated challenge). A Service authenticates identically with no `user_id`. The server enforces `header.author == jwt.member_id` on every POST even though it MAY skip signature verification.

## Envelope and control plane

The adversarial security review ([minimal-sync-server-security-review.md](./minimal-sync-server-security-review.md), F1–F23) is **adopted in full**; this section is its condensed normative core.

**The control plane lives in the log.** Grant, Revoke, Rotate, MemberRegister, MemberKeyRotate are signed control ops chained to Root; server tables are a materialised index for its own authz, authoritative for nobody. Clients pin `root_pk` at first escrow unwrap (TOFU against the passphrase, not the server) and refuse Members not chained to it. Clients hold a monotone per-Workspace `epoch_floor`; a suppressed rotation is therefore a detectable gap, not a silent downgrade. **Control ops are never compacted.**

**Envelope** (protocol identity):

```
header (canonical, fixed order, length-prefixed):
  suite            u8    # 1 = XChaCha20-Poly1305 + Ed25519; no separate alg field
  op_class         u8    # 1=content 2=control 3=suggestion 4=compaction 5=prune; unknown => quarantine
  workspace_id     16B
  key_epoch        u32
  op_id            16B   # namespaced by author; uniqueness (w, author, op_id)
  author_member_id 16B
  author_key_id    8B    # selects the verifying key
  author_seq       u64   # strictly +1 per author per workspace
  prev_author_hash 32B   # hash of this author's previous envelope
  observed_head    32B   # reserved, zero in v1 (fork-detection gossip is v2)
  nonce            24B
AAD        = the serialized header bytes, exactly
ciphertext = XChaCha20-Poly1305(K_{w,epoch}, nonce, AAD=header, plaintext)
signature  = Ed25519(sk_author, "jeeves/op/v1" || header || ciphertext)
```

Normative rules: AEAD failure is an **alarm surfaced to the user**, never a skipped row. Unknown `suite`/`op_class` ⇒ quarantine, fail-closed; no in-band negotiation. Signature algorithm is a property of the registered member key, never of the envelope. Every signing use of a member key is domain-separated (`jeeves/op/v1`, `jeeves/auth-challenge/v1`, `jeeves/grant/v1`, …). Plaintext is padded to size classes (classes tunable; the padding scheme is v1 format). Per-author chains make truncation, reordering, and rollback of any author's stream detectable; total author silence is indistinguishable from offline (accepted; heartbeat op deferred).

**Recovery escrow:** constant blob `root_sk || master_wrap_key` under Argon2id, root-signed, monotonically versioned, client-enforced KDF floors; per-epoch Workspace keys stored wrapped under `master_wrap_key`. Passphrase-derived material never leaves the device; escrow fetch is rate-limited and audited. Passphrase change is a re-wrap — explicitly *not* a remediation for passphrase compromise (only key rotation is). OPRF-hardened escrow is the v2 upgrade path.

## Suggestions

A **suggestion** is an op of `op_class=suggestion` — a proposed change from a `suggester` Member, quarantined from state by rule:

> **A reducer never reads a suggestion op to compute state.**

**Promotion** is the owner authoring a full authoritative content op — carrying the change itself, signed by the promoter, with a provenance reference to the suggestion's `op_id` inside the ciphertext. **Discard** is a tiny authoritative resolution op (synced, so no device re-reviews). Consequences: promote-with-modification is free; old clients are fail-closed (unknown op_class quarantines); the server segregates suggestions content-blind on `(grant.role, op_class)`; **auto-promote** is purely client-side policy — the log records provenance, never trust. Resolved suggestions become prunable; unresolved suggestions are the only GC-exempt class.

## Compaction and GC

No workspace-level snapshot artifact. Compaction is **entity-level** and collapses into the op mechanism:

- A **compaction op** is an authoritative op re-asserting every field of one entity. Protocol-identity requirement: it carries the **original per-field HLCs** (and authorship provenance), never the compactor's clock — otherwise compaction wins merges it must lose against offline edits pending at older HLCs.
- A **prune op** is a signed op enumerating the seqs its compaction supersedes. **v1 prunes are soft deletes:** the server sets `compacted_by` on the enumerated rows and never deletes — history stays available to the user on demand. Default pulls exclude compacted rows; a history view requests them. Soft→hard is an easy later shift; hard→soft is impossible. Accepted cost: server storage only grows in v1. Signed prunes keep legitimate GC distinguishable from server truncation — which is why a prune op is itself never pruned or compacted, alongside control ops. A compaction op is an ordinary compaction target: the next compaction of the same entity supersedes it.
- Soft delete retains old-epoch ciphertext indefinitely, so members retain historical epoch keys — which the `master_wrap_key` escrow structure provides for free.
- Fresh-device bootstrap = replay the compacted log (one stream, no snapshot+tail merge). A stale device (cursor below pruned history) resets the same way, then applies and uploads its pending local ops as normal — aggressive compaction forces resets, never loses authored data. Tombstone floor / stale-member cutoff: 180 days; beyond it, pending ops referencing entities absent-without-tombstone are quarantined for user review, not applied and not dropped.
- Knobs: compact an entity at ~20 live ops; prune grace of a few days; unresolved suggestions never pruned. Control ops never compacted.

## Authorization matrix

All checks content-blind. **D** = Device (member JWT), **S** = Service (member JWT, no `user_id`), **U** = user bootstrap credential, **OP** = service-operator credential.

| Operation | Principal | Server check |
|---|---|---|
| `POST /w/{w}/ops` content | D/S, role ∈ {owner, participant} | `jwt.member == header.author`; live Grant; `key_epoch ≥ current − 1`; `author_seq == last+1`; `(w, author, op_id)` unused; size cap; rate limit |
| `POST /w/{w}/ops` suggestion | any live Grant (incl. suggester) | as above; segregated by cleartext `op_class` |
| `POST /w/{w}/ops` control | owner or Root-signed | as above; server materialises into its index; chain validity is the client's job |
| `POST /w/{w}/ops` compaction/prune | role = compactor (or owner) | as above; prune sets `compacted_by`, never deletes (v1) |
| `GET /w/{w}/ops?since=` | live Grant | no server-persisted cursor |
| `PUT /w/{w}/keywraps` (rotation) | owner | matching `rotate` control op with equal `keywrap_digest` |
| `GET /w/{w}/keywraps/me` | the member | `jwt.member == row.member` |
| `POST /members` (enrol) | U | stores pubkeys only; **no authority** until a Root-signed MemberRegister lands |
| `POST /members/{m}/challenge` | key possession | Ed25519 over server nonce, domain-separated |
| `POST /services` / kex-key rotate | OP | identity key pinned app-side for first-party services (rotated by app update), by user-confirmed fingerprint or app-trusted signed directory for third-party/self-hosted; subkeys signed by identity key |
| `GET /w/{w}/recovery` | U, rate-limited + audited | never accepts passphrase-derived input |
| `PUT /w/{w}/recovery` | Root-signed blob | verify against stored `root_pk`; version strictly greater |
| Revoke member | owner (participants); Root (owners) | refuse POST **and** GET immediately |
| Create workspace | U | genesis control op self-signed by Root |

## Migration

### Implementation stance: clean implementation

The Minimal Sync Server is planned and architected **in vacuum, as if greenfield**. Legacy behaviour and data are preserved only where preservation is ultra-cheap — an entity that needs no deletion stays and syncs itself as the first copy through the new pipeline. The moment accommodating legacy behaviour or data would introduce *any* branching — compat shims, versioned code paths, dual-writes, tolerant readers for retired shapes — we do not accommodate. Data safety comes from the migration sequence below (the device store is the truth; the old stack stays read-only), never from in-protocol compatibility. In the normal case this is consistent with the no-destructive-migrations rule rather than an exception to it: the server's copy is a cache, and nothing that exists only on the server and on no device is treated as user data.

**Authorized fallback — one-time exception, no precedent (decided 2026-07-27).** If clean cutover proves harder than the sequence below, this migration — and only this migration — may go as far as: add an export to a legacy build, manually export the data from a client, dump everything (local stores and server), and restore from the export through an import path (as the Nirvana import did). Destructive of the *stores*, not of the *data* — the export file carries it across. This does not soften the standing rule for any future schema change; it exists so that no amount of legacy-compat branching can ever look cheaper than cutting over.

### Sequence

The client is the source of truth; the server's copy is a cache. There is no server-side data migration.

1. Converge every device on the current PowerSync stack; verify (especially any partially-synced client — web/OPFS is the likely laggard).
2. Cut over: one complete device uploads its full local store as ops (`envelope` versioned from day one: `plaintext_v1` now, `aead_v1` when encryption turns on — the Minimal Sync Server ships before E2EE and the envelope swap is a wrapper change, not a protocol change).
3. **The old stack stays up read-only** until confidence is earned. The mirrored schema is not dropped in the PR that ships the op log.
4. Then prune the old backend wholesale (mirrored tables, PowerSync service, upload contracts, `backend/app/ai/`).

Multi-Area Outcomes are resolved before or during cutover per ADR-0025 (user choice, surplus memberships become Labels, surfaced as a Weekly Review pass).

## Accepted risks (recorded deliberately)

- A revoked Member keeps everything it already read; granting a Service is irreversible for read history, and the operator can retain plaintext. Delegation copies hand the recipient plaintext forever.
- The server learns the membership graph, per-member op counts, padded sizes, timing; cleartext `author_member_id` is benign single-User, inter-personal metadata once a Workspace is shared.
- Availability is undefendable — the server can always withhold; every integrity mitigation is detection, not prevention.
- A stolen *unlocked* device is total compromise of that User's Workspaces.
- Passphrase entropy is the E2EE ceiling against a ciphertext-snapshot adversary; in a shared Workspace, the weakest member's passphrase.
- No forward secrecy within an epoch; scheduled rotation bounds it.
- The one-epoch write grace (`key_epoch ≥ current − 1`) lets a survivor's in-flight op land at the old epoch after a revoke+rotate, where the revoked Member can still read it. Accepted deliberately (review Q5: in-flight epoch-*N* ops from survivors are applied) — and the reason revoke+rotate must be prompt. Ops at the old epoch from the *revoked* Member are quarantined, not applied.
- Authorization is whole-Workspace-granular by construction — which is why `user_preferences` has its own Workspace and the AI is a suggester.

## Deferred (v2 by nature, hooks reserved in v1)

OPRF-hardened escrow; cross-author fork-detection gossip (`observed_head` ships zeroed); member heartbeat ops; out-of-band member key verification (mandatory the moment two Users share a Workspace); shared-substrate co-ownership; Workspace UI/UX (one implicit Workspace until then).
