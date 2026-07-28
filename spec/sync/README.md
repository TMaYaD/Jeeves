# Sync protocol golden vectors

Language-neutral, **frozen** fixtures for the Minimal Sync Server's v1 op
envelope (ADR-0026, ADR-0028). They live outside `app/` and `backend/` because
neither owns the protocol: two independent codecs implement it, and these files
are the thing both of them are measured against.

| File | Pins |
|---|---|
| `envelope_v1_vectors.json` | The 158-byte header at every field offset, the body framing and its three padding rules, the signing domain `jeeves/op/v1`, exact signature and envelope bytes, the deterministic id derivations, and one negative vector per fail-closed refusal. |
| `reducer_v1_vectors.json` | Field-grain HLC last-write-wins: ordering, idempotence, the member-id tie-break, tombstones in both directions, the F15 guard scoping, and what quarantines. |

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
