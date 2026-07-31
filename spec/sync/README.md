# Sync protocol golden vectors

Language-neutral, **frozen** fixtures for the Minimal Sync Server's v1 op
envelope (ADR-0026, ADR-0028). They live outside `app/` and `backend/` because
neither owns the protocol: two independent codecs implement it, and these files
are the thing both of them are measured against.

| File | Pins |
|---|---|
| `envelope_v1_vectors.json` | The 158-byte header at every field offset, the body framing and its three padding rules, the signing domains, exact signature and envelope bytes, the deterministic id derivations, and one negative vector per fail-closed refusal. Since #548 it also pins the control plane and the trust root: the control payloads and their Root-signed certificates, the cross-author chain link (SHA-256 over the predecessor's *payload* bytes), the recovery-escrow signature preimage and blob layout, the Argon2id floor, and the proof-of-possession challenge preimage. Since #554 it pins the `aead_v1` suite and both KeyWrap flavours — including the cross-language agreement of HKDF-SHA256, which the Python side hand-rolls because PyNaCl ships none (ADR-0037). Since #555 it pins compaction and prune: the class-4 snapshot shape, the class-5 target enumeration (ADR-0038), and the two directions the plaintext rule runs in. Since #580 it pins the rest of the certificate-binding refusals — the genesis root-pk cross-check, the granter/authority disagreement on both Grants and Revokes, and the certificate-level Workspace binding, which is deliberately a *different* code from the header-level one — plus the sub-order between the genesis Workspace and root-pk checks, via a vector that violates both at once (ADR-0032, ADR-0039). |
| `reducer_v1_vectors.json` | Field-grain HLC last-write-wins: ordering, idempotence, the member-id tie-break, tombstones in both directions, the F15 guard scoping, and what quarantines. Also the non-LWW merge strategies as join-semilattices (ADR-0030), permutation-flagged where associativity is the property; strategy *selection* — a `user_preferences` op carries the `key` that picks its lattice, and a value write without one is refused rather than defaulted (ADR-0033); and since #555 the reduction *equivalence* a compaction op claims — the snapshot alone reduces to what its originals reduce to, and alongside them it is absorbed in every order. |

The envelope file's sections, and what each is for:

| Section | Pins |
|---|---|
| `protocol` | Sizes, offsets, served suites and op classes, the signing domains, the control-payload constants, the `aead_v1` body rule and AAD, the KeyWrap info domains and widths and digest preimage, the escrow blob layout and KDF floor, the challenge preimage shape, and the prune target bound and shape rules. The two suite-rule directions are named sets here rather than prose: `must_stay_plaintext_op_classes` (control and prune, because the server acts on them) and `plaintext_refused_at_keyed_epoch_op_classes` (content and compaction, because they carry entity state). |
| `identities` | The spec user, workspace, Root and two device keypairs — seeds included, so both codecs reproduce every signature below rather than trusting one. |
| `header_vectors` / `vectors` / `negative_vectors` | Header offsets, whole content envelopes, and one fail-closed refusal each. |
| `control_vectors` / `negative_control_vectors` | One canonical control chain — genesis, grants, a MemberRegister, a revoke, and the `rotate` that turns encryption on — plus the codec-level control refusals. Position and chain rules need receiver state a vector cannot carry, so they are pinned by the route and harness suites instead. |
| `aead_vectors` / `negative_aead_vectors` | Whole `aead_v1` envelopes over the spec identities, in both directions: seal to exact bytes *and* open back to the framed plaintext. The framed plaintext is asserted byte-identical to what `plaintext_v1` would carry, which is how "`aead_v1` is a body wrapper" is pinned rather than described. The negatives cover a tampered ciphertext and a tampered header **re-signed**, so the AEAD is what refuses them rather than the signature getting there first — that is the AAD binding under test. |
| `keywrap_vectors` | Both wrap flavours, the `keywrap_digest` over a two-member set, and two misrouting refusals. Every wrap is pinned *and* unwrapped back to the epoch key: the sealing and opening key schedules must be one function, and an asymmetry surfaces only as "the wrap never opens" long after the bytes are frozen. These vectors carry their own **seeded** X25519 pair — the certificates' `kex_pk` values are labelled hashes with no known scalar, which was fine while no codec did key agreement but leaves the reverse direction unpinnable. |
| `compaction_vectors` / `prune_vectors` | The two classes #555 turns on. A class-4 snapshot with a clock on **every** field, one of them naming a member other than the compactor — that per-field provenance is the whole mechanism, and the negatives pin what happens without it. A class-5 prune naming its compaction by `op_id` and attesting chain positions with their envelope hashes, which is why a bare seq would not do (ADR-0038). Both are suite 0x00; for prune that is permanent. Whether a target row exists, is already compacted, or matches the stored envelope is receiver *state*, so it lives in the route and harness suites instead. |
| `escrow_vectors` / `member_challenge_vectors` | Signature preimages and signatures for the escrow record (at two versions, so the version binding is visible) and for a transport challenge. |

Asserted by:

- `backend/tests/sync/test_envelope_vectors.py`
- `app/test/sync/envelope_vectors_test.dart`
- `app/test/sync/reducer_vectors_test.dart`

## Do not regenerate these to make a test pass

`backend/tools/generate_sync_vectors.py` produced them once and is run by hand,
never by a test or by CI. That is the whole mechanism: if a test could
regenerate the expectation, a codec change would silently rewrite the thing it
was supposed to be checked against, and the Dart and Python implementations
could drift apart while both stayed green.

A diff to either file is a **protocol change**. Expect it to be reviewed as one,
and expect both suites to have been run.

```bash
cd backend && uv run python tools/generate_sync_vectors.py
```
