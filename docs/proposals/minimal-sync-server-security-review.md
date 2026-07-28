# Adversarial security review — Jeeves Minimal Sync Server design

> Historical note: at review time the design was working-titled "dumb sync
> server"; occurrences of "dumb" in the verbatim body below refer to what is
> now the Minimal Sync Server.

> Produced 2026-07-27 by an adversarial design-review agent (Fable) against
> `tmp/sync-security-design-state.md`. Verbatim report.

## Verdict

The bones are right: an append-only per-workspace op log, random per-epoch symmetric keys, XChaCha20-Poly1305 with an AAD that binds workspace/epoch/op/author, and per-op Ed25519 signatures from day one is the correct shape, and the "delegation over co-ownership" stance buys you an enormous amount of avoided complexity. But the design has one structural flaw that currently voids most of the cryptography, and it is not in the envelope: **the authorization plane (member pubkeys, grants, roles, revocations, rotations) lives in mutable server-owned tables and is explicitly not yet signed ("columns reserved now, enforcement later"), while the data plane is a signed append-only log.** Per-op signatures are only as good as the registry the verifier resolves `author_member_id` against; if that registry is server-supplied and unauthenticated, a malicious server simply enrols its own member and signs whatever it likes. The fix is cheap and compatible with every stated constraint (including the single-device passphrase-only enrolment requirement): give each User a **random root keypair escrowed under the passphrase**, and move grants/revocations/rotations into the signed log as control ops chained to that root. Second structural gap: nothing binds an op to its predecessor, so the server can truncate, omit, reorder and roll back invisibly — and the most damaging omission is a *rotation*, which is an epoch downgrade by silence. Third: the Service identity's pubkey is pinned by fetching it from the very server it is supposed to protect you against. Everything else below is smaller — but the three above must be settled before the log format ships.

---

## Findings, by severity

### F1 — Member key registry is unauthenticated; per-op signatures buy nothing against a malicious server
**Critical. Protocol-identity — must ship with v1.**

The client rule is "reject on signer ≠ claimed author's registered key." The registered key comes from the server's `members` table. A malicious server (or anyone with a stolen user JWT, F10) registers member `M_evil` with its own Ed25519 key, grants it, and posts ops signed by it. Every client accepts them: the signature verifies against the key the client was told to expect. The grant chain is the defence and it is deferred — but the deferral is not safe, because a signature scheme over an unauthenticated key registry is decoration. The server can also *substitute* an existing member's `sign_pk`/`kex_pk` (silently re-pointing future grants at a key it holds).

Note that "enforcement later" also cannot be retrofitted: ops signed by an unchained member during the deferral window can never be retroactively attributed, exactly the argument the design already makes for per-op signatures.

**Minimal fix.** At workspace/user creation, generate a **random** root Ed25519 keypair (`root_sk`, `root_pk`) — *not* derived from the passphrase, so a passphrase change is a re-wrap, not a root rotation. Store `root_sk` in the escrow blob under Argon2id(passphrase). Every member registration is a control op signed by `root_sk` (or by an owner whose own registration chains to `root_sk`), covering `(workspace_id | member_id | member_kind | role | sign_pk | sign_key_id | kex_pk | kex_key_id | valid_from_epoch | granter_member_id | grant_id)`. A device enrolling with only the passphrase has `root_sk` in hand for the duration of the enrolment and signs its own registration — no second device, constraint respected. Clients pin `root_pk` on first successful unwrap (TOFU against the passphrase, not against the server) and refuse any member not chained to it.

---

### F2 — Control plane is mutable server state, not signed log; rotation can be downgraded by omission
**Critical. Protocol-identity.**

`grants(...)` is a table. Nothing signs "member M was revoked at epoch 4," and nothing orders that fact against the op stream. Consequences, all reachable by a merely *selective* (not even forging) server:

- **Rollback re-admission.** Serve the pre-revocation grant row. A device that missed the revocation re-admits `M`. There is no signed statement it can compare against, and no monotonic counter to notice the rollback.
- **Epoch downgrade by omission.** Withhold the rotation from an honest device. It keeps writing at epoch *N*. The member revoked at *N+1* reads every one of those ops. This is the highest-value server attack in the whole design and it requires no cryptography at all — just silence.
- **Revoked-member liveness.** The design says the revoked member "keeps what it already read." Nothing says it stops *writing*, and with revocation living only in a server table, clients cannot independently enforce a cutoff.
- **Role elevation.** The recorded grant-signature payload `(workspace_id, member_id, member_type, sign_pk, kex_pk, key_epoch, added_at)` **omits `role`.** Even once the chain is enforced, the server can present a participant's grant as an owner grant. Also missing: `granter_member_id`, a `grant_id`/nonce, and any validity window.

**Minimal fix.** Three parts. (a) Split **Grant (the authorization fact)** from **KeyWrap (the delivery of `K_{w,epoch}` to one member)** — see F19. (b) Grant, Revoke, Rotate, MemberRegister and MemberKeyRotate become **control ops in the log**: signed, unencrypted (the server already knows all these fields), carrying `op_class=control`, ordered by the author chain of F3 and referencing the prior control op by hash. The server table becomes a materialised index for its own authz decisions, authoritative for nobody. (c) Every client maintains a persisted, **monotone `epoch_floor` per workspace** and refuses to write below it; a rotate op raises the floor.

---

### F3 — No per-author chain: truncation, omission, reordering, rollback are all invisible
**Critical (it is the detection primitive F2 depends on). Protocol-identity.**

`seq` is server-assigned and unsigned; `received_at` is server-assigned; the HLC is inside the ciphertext and only totally orders what you actually received. A server can drop any op forever, replay an old prefix, serve member A a view without member B's ops, or roll a device back past its own writes. There is currently zero signal.

**Minimal fix.** Add to the signed cleartext header, per author per workspace: `author_seq` (u64, strictly +1, no gaps) and `prev_author_hash` (32B, hash of that author's previous envelope). Now any member detects a gap in any other member's stream the moment a later op from that author arrives, and a device always detects rollback of its own writes. Also reserve a 32-byte `observed_head` field (all-zero in v1) so cross-author fork detection can be enabled later without a format break.

Residual: total silence from an author is still indistinguishable from that author being offline. Optional cheap mitigation, deferrable: a signed daily heartbeat op per member, with a client-side "member X has been silent for N days" warning.

---

### F4 — Service identity pubkey is pinned by fetching it from the server it must be pinned against
**Critical. Decide before the first Service grant ships; not log-format.**

The "registered, not owned" decision is justified by "a published, pinnable service pubkey closes the enrolment MITM window." It does not, if publication means `GET /services/ai` from the Jeeves backend. The server substitutes its own X25519 key, the user's device wraps `K_w` to it, and the server reads that workspace in plaintext forever. TOFU on a key served by the adversary is not TOFU.

**Minimal fix.** The Service *identity* key must be rooted outside the sync server: ship a first-party service trust store **compiled into the app binary** (rotated by app update), and for third-party/self-hosted services require an explicit fingerprint the user confirms out-of-band (or a service directory signed by a key baked into the app). Combine with F5 so the pinned identity key is long-lived and never needs a campaign.

---

### F5 — One Service KEX key across all Users; rotation is a global campaign with an undefined overlap window
**High. Protocol-identity (grant must name a key id); the rest deferrable.**

"Blast radius is no worse — per-user keys on one compromised box leak identically" is the weak link in the SETTLED note, and I'd push back on it. That equivalence holds only under a monolithic, unsegmented deployment. It is not a protocol property: per-tenant keys permit partial compromise, per-user revocation without touching anyone else, per-tenant KMS/enclave policies, and meaningful audit. With one key, compromise of one X25519 private key decrypts *every* granting User's workspace, and rotation is a coordination campaign across every user's device with an explicitly ambiguous overlap window ("the grant model should tolerate overlapping old+new" — two engineers will implement that four different ways).

**Minimal fix, and it keeps everything the SETTLED note wanted.** Split the Service's identity from its wrap key: a long-term **Ed25519 identity key** (pinned per F4, closes the MITM window, never rotates) which *signs* short-lived **per-User X25519 KEX subkeys**, each with `kex_key_id` and `valid_from`/`valid_until`. A User's device verifies the subkey against the pinned identity key and wraps to it. Rotation becomes a lazy per-user re-wrap with no campaign and no ambiguous window; the overlap is expressed by two subkeys with overlapping validity, and the Grant/KeyWrap names `kex_key_id` explicitly. Additionally: Service grants SHOULD carry `not_after` so an abandoned grant lapses, and Service grants SHOULD default to `role=suggester` (F11).

---

### F6 — Envelope layout: AAD ≠ signed header; fields signed-but-not-AAD'd and AAD'd-but-not-in-header
**High. Protocol-identity.**

As recorded: header = `version | key_epoch | author_member_id | nonce | sign_alg`; AAD binds `(workspace_id, key_epoch, op_id, author_member_id)`; signature covers `header || ciphertext`.

- `version` and `sign_alg` are signed but **not in the AAD** → they are unauthenticated with respect to the key. Harmless today, a ciphersuite-confusion vector the moment there is a second suite.
- `workspace_id` and `op_id` are in the AAD but **not in the header** → the verifier obtains them from *server-supplied row columns*. AEAD will fail if the server lies, but that failure is indistinguishable from "I don't hold this key / wrong epoch," which clients will be tempted to treat as a skip. Silent skip on AEAD failure is the single most likely implementation mistake here, and it converts several server attacks into no-ops-that-look-like-normal-operation.
- Nothing in the header identifies **which** of an author's signing keys to verify with (breaks the Service rotation overlap, F5, and any device key rotation, F8).

**Minimal fix.** Make AAD *literally the serialized header bytes*, and put everything in the header:

```
header (canonical, fixed order, length-prefixed):
  suite            u8    # 1 = XChaCha20-Poly1305 + Ed25519. No separate alg field.
  op_class         u8    # 1=content 2=control 3=suggestion; unknown => quarantine
  workspace_id     16B
  key_epoch        u32
  op_id            16B
  author_member_id 16B
  author_key_id    8B    # truncated H(signing pubkey)
  author_seq       u64
  prev_author_hash 32B
  observed_head    32B   # reserved, zero in v1
  nonce            24B
AAD        = header (all of it, exactly as serialized)
ciphertext = XChaCha20-Poly1305(K_{w,epoch}, nonce, AAD=header, plaintext)
signature  = Ed25519(sk_author, "jeeves/op/v1" || header || ciphertext)
```

Then: no field is signed-but-unauthenticated or authenticated-but-unsigned; the server's `workspace_id`/`op_id`/`author` columns are a pure index that the client cross-checks against the envelope; and **AEAD failure is always an alarm**, never a skip (state this as a normative rule: an op whose AAD-bound header disagrees with the stream it arrived in is a server-integrity event surfaced to the user, not a filtered row).

Replay analysis under this layout is clean: cross-workspace replay fails (workspace_id in AAD), cross-epoch replay fails (key_epoch in AAD, and the key differs), same-workspace/same-epoch replay is a duplicate `op_id` (F13), and re-attribution fails (author in AAD *and* under the signature). Nonce handling — 24-byte random XChaCha nonces across many independent offline writers — is correct.

---

### F7 — `sign_alg` in the envelope, and Ed25519-only precludes hardware-backed member keys
**High. Protocol-identity.**

Two problems in one field. First, a negotiable algorithm identifier inside a signed header is the JWT `alg` footgun; the verifier must select the algorithm from the **member's registered key type**, never from the envelope. Delete `sign_alg`; fold the AEAD into a single `suite` byte.

Second, an easy-to-miss consequence of "Ed25519 is settled": iOS Secure Enclave is **P-256 only**, and Android Keystore's Ed25519 support is spotty/absent on real fleets. Mandating Ed25519 means member private keys are software keys in Keychain/Keystore — exportable by anything that can read app storage on a compromised device. That may be fine, but it should be a decision, not an accident. Conveniently, the fix for the first problem gives you the second for free: **algorithm is a property of the registered member key, not of the envelope**, so a P-256-in-Secure-Enclave member becomes possible later with no format break.

Related, same fix cost: **domain-separate every use of a member's Ed25519 key.** It will sign ops, transport challenges (F10), grant certificates and snapshots. Without distinct prefixes (`"jeeves/op/v1"`, `"jeeves/auth-challenge/v1"`, `"jeeves/grant/v1"`, `"jeeves/snapshot/v1"`) a server can get a signature in one context and replay it in another — most concretely: get a device to sign a login challenge whose bytes are a valid grant body.

---

### F8 — Member key rotation is entirely absent; compromise-rotation and hygiene-rotation are different flows
**High. Protocol-identity (key ids); flows deferrable.**

The Member holds "one Ed25519 + one X25519 keypair" with no lifecycle. Missing: how a device rotates its own keys, and — critically — the distinction between *hygienic* rotation (old key signs new key, overlap window) and *compromise* rotation (the old key is exactly what the attacker holds, so a self-signed rotation is the attack). Also, the signing key and the KEX key are conflated into one "Member keypair" despite having different rotation drivers.

**Minimal fix.** Separate `sign_key_id` and `kex_key_id` with independent validity ranges; `author_key_id` in the header selects the verifying key. Hygienic rotation = a control op signed by the *old* key introducing the new one. Compromise rotation = revoke the member and register a new one, authorised by an owner or by `root_sk`, never by the compromised key. Record that a member's *identity* survives sign-key rotation (so history stays attributed) but not compromise-rotation.

---

### F9 — Snapshots destroy per-op authorship; no defined signer, no defined trust rule
**High. Protocol-identity for the header + the "control ops are never compacted" rule.**

"Snapshots are envelopes too" is the whole problem: an op is a signed *statement by its author*; a snapshot is a *reduction over other people's statements*. Whoever signs a snapshot is asserting content they did not author. A compromised (or merely buggy) member's snapshot can contain anything, attributed to anyone, and once the underlying ops are GC'd there is nothing left to check it against. This is currently the least-specified area and it can silently undo every other guarantee.

**Minimal fix, three rules.**
1. **A snapshot is a local optimisation, not a trust artifact.** Default: a member consumes only snapshots *it* produced (server stores them keyed by `(workspace, author_member_id)`, encrypted under the workspace key with the same AAD discipline). Fast restore for that device, zero new trust.
2. **Control ops are never compacted.** Membership, revocation and rotation history stays in the log forever. It is tiny, and it is the only thing that lets a fresh device reconstruct who was allowed to say what.
3. If cross-member snapshots are ever wanted, the snapshot header must carry the **frontier it covers**: the set of `(author_member_id, author_seq_high_water, prev_author_hash)`. A recipient can then verify the frontier is consistent with what it has seen and detect a snapshot claiming coverage of ops that never existed. Content trust still equals signer trust, so restrict published snapshots to `role=owner`, and say so.

Also note the useful interlock: **rotation is the natural compaction point.** A snapshot taken at epoch *N+1* covering everything ≤ `covers_seq` is what eventually lets a device discard the epoch ≤ *N* keys and ciphertext.

---

### F10 — Transport auth is user-scoped; a stolen JWT does far more than op signatures constrain
**High. Not log-format, but must be decided before the server ships.**

Today `sub = user_id` (`backend/app/auth/tokens.py`, `dependencies.py`) and no member identity exists in the token. A stolen access token, with no device keys, can: pull every ciphertext op of every workspace (harmless alone); **fetch the recovery escrow blob** → offline passphrase grinding (F12); **register a member** → with F1 unfixed, that is signature-forgery-equivalent; **overwrite the recovery record** → denial-of-recovery (F16); write junk ops and exhaust storage; read all metadata (authors, sizes, timing, cursors); and, if grants are user-JWT-authorized, mint grants. Also, revoking a device today does not revoke its transport credential.

**Minimal fix.** Member-scoped tokens. A Device proves possession of its Ed25519 key over a server nonce (domain-separated per F7) and receives a JWT carrying `member_id` (and `user_id`); refresh tokens are per-member so revoking a member kills its transport credential. A **Service has no User**, so it authenticates the same way — `sub = member:<id>`, `user_id` absent — which is exactly what `members.user_id NULL` should imply. The server then enforces `header.author_member_id == jwt.member_id` on every POST: a one-comparison check with no crypto that makes lying about authorship impossible even for a server that never verifies signatures. **This means the server SHOULD do that check even though it MAY skip signature verification** — otherwise its own authz (e.g. "revoked members cannot post") is bypassed by simply claiming to be someone else.

---

### F11 — No `op_class`: the suggester concept (and every future op kind) is fail-open on old clients
**Medium-high. Protocol-identity — the field must exist in v1 even if suggesters ship in v3.**

If "is this a suggestion?" is a property of the *grant* (`role=suggester`), an older client that doesn't consult roles applies a suggester's ops as real content — fail-open, silently, exactly where the AI service lives. And the server cannot quarantine without content inspection.

**Minimal fix.** `op_class` in the signed cleartext header (F6), with the normative rule **unknown class ⇒ quarantine, never apply**. That makes the extensibility story fail-closed permanently, and answers Q4's server question: yes, the server can quarantine/segregate suggestions with zero content inspection, keyed on `(grant.role, op_class)`. Promotion is the owner emitting a *new* content op referencing the suggestion's `op_id` — never a mutation of the suggestion — which preserves attribution and keeps the reducer monotone.

Strong recommendation attached: **the AI Service should be `suggester` by default.** That single choice downgrades "compromised multi-tenant AI service" from "silently rewrites your GTD system across all users" to "floods review queues." Given F5's blast radius, this is the highest-leverage cheap control in the design.

---

### F12 — Recovery escrow is an offline passphrase-guessing oracle with no KDF floor
**High. Deferrable in format, not in policy.**

The blob is `Argon2id(passphrase)`-wrapped and fetchable by anyone with a JWT, by the server, and by anyone holding a DB snapshot. It unwraps to the workspace key, which decrypts everything. So **passphrase entropy is the entire E2EE security level against the snapshot-theft adversary** — typically 30–50 bits for a human-chosen phrase, which Argon2id at phone-affordable parameters does not save.

Additional specific gaps: no minimum KDF parameters enforced by the client (a malicious server can hand back weakened params *at passphrase-change time* so the next blob is cheap to grind); no monotonic version, so the server can serve a stale blob from before a rotation or passphrase change; nothing forbids the client from sending any passphrase-derived value to the server (turning the flow into an online oracle); and a bogus blob served deliberately farms retry attempts under a "wrong passphrase" prompt.

**Minimal fix, in cost order.** (a) Client-enforced Argon2id parameter floor, params inside the blob, refuse anything below floor on both read and write. (b) Blob carries a monotonic version and is root-signed; clients refuse a version lower than the highest seen. (c) The client never transmits passphrase-derived material — fetch blob, unwrap locally, always. (d) Rate-limit + audit + second-factor the escrow *fetch* (kills the stolen-JWT path; does nothing against server compromise). (e) Default to a **generated** high-entropy passphrase (diceware, 5–6 words) rather than a user-chosen one — this is the only change that actually moves the ceiling. (f) Medium-term, the real answer: an **OPRF-hardened escrow** (server-blinded KDF, à la Signal SVR), which makes DB-snapshot offline guessing impossible and online guessing rate-limitable, at the cost of the server holding a secret it must not lose.

Structural tidy-up while you're here: escrow a constant-size blob = `root_sk || master_wrap_key`; every epoch key is stored server-side wrapped under `master_wrap_key`. Then a passphrase change is a single re-wrap, the root key is stable, and history across all epochs remains recoverable.

---

### F13 — `op_id` uniqueness is not namespaced by author
**Medium. Protocol-identity (it's a uniqueness key).**

`UNIQUE(workspace_id, op_id)` is doing real security work (it is what makes verbatim replay a no-op) so it should be stated as a security requirement, not an idempotency convenience. But it also lets one member burn another member's `op_id` space; with random UUIDs that's not practically exploitable, and the fix is free.

**Minimal fix.** Server uniqueness key `(workspace_id, author_member_id, op_id)`; better still, define `op_id` as derived from `(author_member_id, author_seq)`. Clients must independently dedupe by op_id **and treat a second, differing envelope under the same op_id as a server/author integrity event** — the server may accept duplicates the schema would have rejected.

---

### F14 — Revoke and rotate are not atomic; orphaned grants and concurrent-owner races are undefined
**Medium (High once multi-user). Deferrable, but write the rule now.**

Between "revoke M" and "rotation to epoch N+1 completes and everyone re-wraps," every op written by an honest member is still readable by M. And rotation requires the rotating device to hold current, authentic KEX pubkeys for *all* survivors — which depends entirely on F1/F2.

**Minimal fixes.** (a) **Never emit a revoke without the accompanying rotate**; treat them as one operation, and if the rotating device cannot re-wrap for all survivors, the revocation is blocked and surfaced, not staged silently. (b) Define **orphaned grant** = a valid Grant with no KeyWrap at the current epoch; that is a nameable, detectable, healable state — surface it rather than letting the member fail to decrypt mysteriously. (c) **Revoking a granter does not cascade** — grants made while the granter was in good standing survive; chain validity is evaluated **at the log position of signing** ("was the granter an owner in good standing when this grant op landed?"), not at read time. Otherwise retiring a founding device orphans the entire tree, which is a self-lockout DoS. (d) The workspace genesis record is self-signed by `root_sk`, and the founding *device* is merely the first owner — revoking it must not invalidate anything. (e) Concurrent mutual revocation by two offline owners: resolve with a deterministic, identically-applied tie-break (earliest HLC, then lowest member_id), and quarantine the loser's subsequent ops rather than dropping them. (f) Only `root_sk` may remove an owner; owners may remove participants — otherwise one compromised owner evicts everyone including the founder.

---

### F15 — HLC is unbounded client input; `hlc.device_id` is unbound to the header author
**Medium. Reducer rule, deferrable.**

LWW-by-HLC means any member — including the AI service — can set `wall_ms` to 2099 and permanently pin any field against all future edits. Also, `hlc.device_id` lives inside the ciphertext and duplicates `author_member_id`; if they may differ, a member can win tie-breaks under someone else's identity.

**Minimal fix.** Reducers quarantine (do not apply) ops whose `wall_ms` exceeds local time by more than a bounded skew (~5 min); ops far in the *past* are always fine (legitimately offline devices). Reducers reject `hlc.device_id ≠ header.author_member_id`.

---

### F16 — Recovery record writes are unauthorized: denial-of-recovery
**Medium.** Anyone with a user JWT overwrites the escrow blob with garbage (or with a blob under *their* passphrase). Existing devices don't notice — they hold the key. The damage lands later: the legitimate user can never enrol a second device, and in the single-device-loss scenario the data is gone. **Fix:** escrow writes must be root-signed with a monotonic version, verified by the server (it can check an Ed25519 signature against a stored `root_pk` without learning anything) and by clients.

---

### F17 — Metadata: op sizes and server-persisted cursors
**Medium/Low.** `collection` is inside the ciphertext (good), but ciphertext length distinguishes a tombstone from a long note, and per-op timing plus per-member cursors reconstructs work patterns, sleep schedule and AI invocation frequency. **Fixes:** pad plaintext to size classes (needs a length-prefix/padding scheme *inside* the plaintext format — so it is a format decision, decide now even if the classes are tuned later); and **do not persist cursors server-side at all** — make `since` a pure client parameter, so a DB snapshot doesn't reveal each device's last-seen position. The design listed cursors under "server's total knowledge"; that's an unforced concession.

---

### F18 — Rotation only on revocation ⇒ no bounding of ciphertext-only exposure
**Low/Medium.** There is no forward secrecy, but against a device-compromise adversary that's moot (the device holds the plaintext store anyway). It is *not* moot against the ciphertext-only adversary: a server that snapshotted years of ciphertext, plus one later-leaked epoch key, decrypts everything in that epoch. **Fix:** rotate on a schedule (quarterly, say) in addition to on revocation. Cheap, bounds the window, and gives the compaction point in F9 a regular cadence.

---

### F19 — Entity factoring: Grant conflates an authorization fact with a key delivery
**Medium. Protocol-identity (it changes what is signed and where it lives).**

Member/Author/Recovery are right — keypairs on the Member is the correct fix already made, and Author-as-role-not-entity is correct. **Grant is doing two jobs**: asserting "M may participate in W with role R" (public, must be signed, must be in the log, changes rarely) and delivering `wrap(K_{w,epoch})` (private to one member, one row per epoch, churns on every rotation). Splitting them into **Grant** and **KeyWrap** makes rotation a pure KeyWrap operation that never touches the authorization graph, and makes "orphaned" a nameable state (F14b).

Also **missing entities**: **Revocation** as a first-class signed fact (member revocation, grant revocation and key rotation are three distinct operations conflated into one bullet); **Epoch** as a thing with a lifecycle (`created_by`, `retires_epoch`, and a `keywrap_digest` proving the wrap-set is complete); **Key** as distinct from Member (a Member has *sequences* of sign and KEX keys with ids and validity — required by F5 and F8); and **Root** (the passphrase-escrowed authority, F1), which is currently modelled only as a wrapping mechanism and needs to be a *signing* authority.

---

### F20 — Trust rules for server-assigned fields are unwritten
**Low, but a guaranteed two-engineer divergence.** Write it down normatively: `seq` is a transport cursor and nothing else — never causality, never conflict resolution, never evidence (BIGSERIAL holes are meaningless and a malicious server renumbers freely). `received_at` is never an input to LWW. Ordering of control ops comes from author chains and explicit hash references, not from `seq`.

### F21 — Version handling must be fail-closed
**Low. Protocol-identity, one line.** A client encountering `suite`/`version` above what it supports **rejects and surfaces**, never "ignores unknown fields," and there is no in-band negotiation.

### F22 — Local at-rest protection is unspecified
**Low/Medium.** Nothing states where member private keys and the Drift/SQLite store live on device. Minimum: private keys in Keychain/Keystore (non-exportable where the algorithm permits, see F7), SQLite encrypted with a Keystore-held key gated on device unlock. Stolen *unlocked* device remains total compromise — accepted.

### F23 — GC/erasure is indistinguishable from truncation
**Low.** Once you offer compaction, "the server pruned below seq X legitimately" and "the server truncated your history" look identical. If GC ships, it must be an author-signed `prune(below_seq)` control op. Deferrable.

---

## Answers to the ten questions

1. **Entity factoring.** Member/Author/Recovery: right. Grant: split into Grant (fact) + KeyWrap (delivery) — F19. Missing entities: Revocation, Epoch, Key (as a versioned thing on a Member), and Root — F19, F1, F8. Failure modes: Grant-without-signed-`role` → elevation (F2); Grant-as-server-row → rollback/omission (F2); Member-with-one-immutable-keypair → no rotation path and no hardware keys (F7, F8); Recovery-as-passphrase-only → single point of both failure and offline attack (F12).
2. **Member ↔ JWT.** F10. Today's user-scoped JWT is far more powerful than op signatures constrain: it can register members (⇒ forgery under F1), fetch and overwrite the escrow, pull everything, and survive device revocation. Fix: member-scoped tokens issued on proof-of-possession of the member signing key; a Service authenticates identically with `user_id` absent, which is what `members.user_id NULL` should mean operationally. The server must enforce `header.author_member_id == jwt.member_id` even if it never verifies a signature.
3. **Grant chain.** F1 (root and enforcement-now), F2 (control ops in the log, role in the signed payload), F14 (validity evaluated at signing position, no cascade on granter revocation, orphan definition, mutual-revocation tie-break, only root removes owners). Rotation interplay: grants are epoch-independent; KeyWraps are per-epoch — that separation is what removes the race entirely.
4. **Suggesters.** F11. Signature/AAD impact: none beyond adding `op_class` to the header (hence to AAD and to the signature). Authorization impact: `(grant.role, op_class)` is a fully content-blind server check, so yes — quarantinable server-side. Promotion is a new owner-signed op referencing the suggestion's `op_id`, never a mutation. Default the AI Service to suggester.
5. **Epoch/rotation.** Exact flow: owner *D* generates `K_{N+1}`; computes survivor set from the head of the control log; emits signed `revoke(member, effective_epoch=N+1)`; emits signed `rotate(from=N, to=N+1, keywrap_digest=H(sorted (member_id, kex_key_id, H(wrap))))` — the digest is what stops the server adding or omitting a wrap; uploads KeyWraps; then writes at *N+1*. Readers raise their persisted `epoch_floor` on observing the rotate op, fetch their KeyWrap, and **keep all historical epoch keys forever** (or until a snapshot at *N+1* covers the old ciphertext, F9). In-flight epoch-*N* ops from survivors: apply, accepting that the revoked member can read them (unavoidable, and the reason revoke+rotate must be prompt). In-flight epoch-*N* ops from the *revoked* member: quarantine. AAD/epoch interaction is sound — `key_epoch` in the AAD makes cross-epoch reinterpretation fail. Downgrade: the attack is omission, not substitution (F2), detected by the author-chain gap in *D*'s stream (F3).
6. **Recovery escrow.** F12 and F16. Also: per-(Workspace, User) records with independent salts are correct (marginally better than one KDF output fanned out by HKDF, which would let an attacker pay one Argon2id per guess for all workspaces). Passphrase change re-wraps the escrow only — and must be recorded as **not a remediation for passphrase compromise**, since the server may have kept the old blob; only workspace-key rotation is.
7. **Enrolment.** Device-by-passphrase: what the server can substitute is (i) the blob — fails AEAD, must alarm rather than prompt "wrong passphrase"; (ii) KDF params, dangerous only at write time (F12a); (iii) an *additional* injected member (closed only by F1); (iv) a stale blob (closed by F12b). Absolute rule: no passphrase-derived value ever leaves the device. Service enrolment: currently broken (F4) — TOFU on a server-supplied key is not TOFU; needs an app-binary trust store or user-confirmed fingerprint.
8. **Multi-user, in the order things break.** (1) F1/F2 — the grant chain stops being deferrable the instant a second User's key must be trusted, and out-of-band verification becomes mandatory as already noted; (2) rotation-on-revocation requires authentic KEX pubkeys for all survivors, so it inherits every F1 weakness; (3) **recovery becomes the shared workspace's weakest link — each co-member's escrow holds the same workspace key, so security = min(passphrase entropy over all members)**; (4) concurrent-owner revocation races (F14e/f) become real rather than theoretical; (5) cleartext `author_member_id`, accepted for one User, starts leaking *inter-personal* activity metadata to the server; (6) delegation copies are irreversible by construction — the recipient has plaintext, and there is no revoking that. Say so in the docs rather than letting anyone expect otherwise.
9. **Envelope/AAD/signature ambiguities.** F6 (layout), F13 (op_id namespace and duplicate handling), F3 (truncation/reordering), F7 (`sign_alg`, domain separation), F21 (version fail-closed), F20 (`seq`/`received_at` semantics). Nonce handling is fine.
10. **Malicious server, detect vs accept.** Detect cheaply and mandatorily: per-author truncation/omission/reordering, rollback of one's own writes, duplicate op_id with differing bytes (all F3/F13); epoch downgrade and grant/revocation rollback (F2's monotone floor + signed control ops); escrow rollback (F12b). Detect later, deferrable: cross-author fork/equivocation — reserve `observed_head` now, enable gossip/head-comparison later (a "compare this 6-word head phrase across your devices" affordance is a surprisingly cheap v2). Accept: withholding/availability (a server can always refuse to serve; detection only, never prevention), traffic analysis after padding, and the membership graph.

---

## Minimal authorization matrix the server must enforce

Principals: **D** = Device member (member-scoped JWT), **S** = Service member (member-scoped JWT via key challenge, no `user_id`), **U** = user bootstrap credential (login only), **OP** = service operator credential (separate realm). All checks below are content-blind.

| Operation | Allowed principal | Server-side check |
|---|---|---|
| `POST /w/{w}/ops` `op_class=content` | D or S with live Grant, role ∈ {owner, participant} | `jwt.member_id == header.author_member_id`; grant exists ∧ not revoked; `header.key_epoch ≥ current_epoch − 1` (flag the −1); `author_seq == last+1` for `(member, w)`; `(w, member, op_id)` unused; size cap; rate limit |
| `POST /w/{w}/ops` `op_class=suggestion` | any member with live Grant (incl. role=suggester) | as above; stored in the same log, segregated by the cleartext `op_class` |
| `POST /w/{w}/ops` `op_class=control` | role=owner, or root-signed | as above; server materialises the effect into its index. Chain validity is the *client's* job |
| `GET /w/{w}/ops?since=` | member with live Grant | grant exists ∧ not revoked. **No server-persisted cursor** (F17) |
| `PUT /w/{w}/keywraps` (bulk, at rotation) | role=owner | owner grant; a matching `rotate` control op with an equal `keywrap_digest` must be present |
| `GET /w/{w}/keywraps/me` | the member itself | `jwt.member_id == row.member_id` |
| `POST /members` (device enrolment) | U | stores pubkeys only — **confers no authority** until a root-signed `MemberRegister` control op lands |
| `POST /members/{m}/challenge` → member JWT | possession of the member signing key | Ed25519 over a server nonce, domain-separated (F7) |
| `POST /services` (register identity key) | OP | out of user scope; the same key must also appear in the app-pinned trust store (F4) |
| `POST /services/{s}/kex-keys` (rotate subkey) | OP | subkey must be signed by the service identity key; clients verify against the pinned key (F5) |
| `GET /w/{w}/recovery` | U, rate-limited + second-factor + audited | N/day cap, exponential backoff; never accepts passphrase-derived input |
| `PUT /w/{w}/recovery` | root-signed blob only | verify Ed25519 under stored `root_pk`; version strictly > stored (F12b, F16) |
| `POST /w/{w}/snapshots` | member with live Grant | stored keyed by `(w, author_member_id)`; readable back only by that member unless role=owner (F9) |
| Revoke member | role=owner (participants); root (owners) | materialised from the control op; immediately refuse POST **and** GET from the revoked member |
| Create workspace | U | genesis control op self-signed by `root_sk` |

---

## Accepted risks worth writing down explicitly

- A revoked member keeps everything it already read. Unavoidable; already accepted.
- Granting a Service is irreversible with respect to read history, and the operator can retain plaintext indefinitely. Categorically larger than a device grant because the box is multi-tenant.
- Delegation copies hand the recipient plaintext forever; there is no un-delegating.
- The server learns the membership graph, per-member op counts, padded sizes, and timing. Padding and dropped server-side cursors reduce it; they do not remove it.
- Cleartext `author_member_id` reveals who wrote each op — benign for one User, inter-personal metadata the day a workspace is shared.
- Availability is not defensible: the server can always refuse to serve or withhold. Every mitigation above is detection.
- A stolen *unlocked* device is total compromise of every workspace that User holds.
- Passphrase entropy is the ceiling on E2EE strength against the ciphertext-snapshot adversary; in a shared workspace the ceiling is the **weakest** member's passphrase.
- No forward secrecy inside an epoch; scheduled rotation (F18) bounds it but does not remove it.
- Members are authorized at whole-workspace granularity. One symmetric key means there is no field- or collection-level restriction and never can be — which is precisely why `user_preferences` gets its own workspace, and why the AI Service should be a suggester.
