# Sync protocol golden vectors

Language-neutral, **frozen** fixtures for the Minimal Sync Server's v1 op
envelope (ADR-0026, ADR-0028). They live outside `app/` and `backend/` because
neither owns the protocol: two independent codecs implement it, and these files
are the thing both of them are measured against.

| File | Pins |
|---|---|
| `envelope_v1_vectors.json` | The 158-byte header at every field offset, the body framing and its three padding rules, all four signing domains, exact signature and envelope bytes, the deterministic id derivations, and one negative vector per fail-closed refusal. Since #548 it also pins the control plane and the trust root: the `member_register` payload and its Root-signed certificate, the cross-author chain link (SHA-256 over the predecessor's *payload* bytes), the recovery-escrow signature preimage and blob layout, the Argon2id floor, and the proof-of-possession challenge preimage. |
| `reducer_v1_vectors.json` | Field-grain HLC last-write-wins: ordering, idempotence, the member-id tie-break, tombstones in both directions, the F15 guard scoping, and what quarantines. |

The envelope file's sections, and what each is for:

| Section | Pins |
|---|---|
| `protocol` | Sizes, offsets, served suites and op classes, the four signing domains, the control-payload constants, the escrow blob layout and KDF floor, the challenge preimage shape. |
| `identities` | The spec user, workspace, Root and two device keypairs — seeds included, so both codecs reproduce every signature below rather than trusting one. |
| `header_vectors` / `vectors` / `negative_vectors` | Header offsets, whole content envelopes, and one fail-closed refusal each. |
| `control_vectors` / `negative_control_vectors` | Two chained MemberRegisters (the first at a zero chain link, the second naming the first's payload hash), and the codec-level control refusals. Position and chain rules need receiver state a vector cannot carry, so they are pinned by the route and harness suites instead. |
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
