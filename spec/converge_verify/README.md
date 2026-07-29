# Converge-verify golden vectors (cutover tooling)

> **Removed by #556.** This directory, the two implementations it pins, and the
> screen that renders their diff exist only for #553 Phase 1 (issue #582): the
> one-shot check that the phone's legacy PowerSync-side local store and the
> legacy mirrored Postgres tables hold the same rows, run and reviewed by the
> user before the Phase-2 reseed. Nothing in the product reads it.

Deliberately **not** in `spec/sync/`. That directory freezes the Minimal Sync
Server's v1 wire protocol and outlives the cutover; this one is scaffolding for
crossing it. Keeping them apart is what lets #556 delete a whole directory
without reading a diff.

| File | Pins |
|---|---|
| `canonical_row_vectors.json` | The column manifest for all twelve synced tables, the declared column exclusions, the canonical row encoding down to its escape table, the tolerant timestamp-parsing **rules**, and one row vector per table plus the refusal cases. |

Asserted by:

- `app/test/cutover/canonical_row_test.dart`
- `backend/tests/test_converge_verify_canonical.py`

Both suites run every vector. They also assert their own hardcoded manifest
equals the one in this file, and — separately — that the manifest still matches
their side's live schema (`powersyncSchema` on the Dart side, the SQLAlchemy
models on the Python side), so a newly synced table fails the suite instead of
going quietly unverified.

## Why the rules are frozen, not a captured serialisation

The obvious way to pin timestamp handling would be to sync real rows against the
compose stack and freeze whatever bytes came back. That would pin the wrong
thing: the compose stack and the deployed stack run different
powersync-service versions, so a format captured from one is not evidence about
the other — and the phone is the only store that matters. `timestamp_parsing`
therefore states a **grammar and a rule set** wide enough to accept every shape
either side can produce (Drift's space-before-offset, app-written UTC `Z`
strings, Postgres microsecond offsets, zone-less legacy text), with explicit
range validation and truncation.

A value the rules refuse never raises. It degrades to a per-row anomaly with a
sentinel in the canonical string, because a throw would brick the report on the
one device the check exists to inspect.

## Do not regenerate these to make a test pass

Every raw row, every `canonical` string, and every timestamp expectation in this
file is hand-authored. The only computed field is `digest`, which is SHA-256
over the hand-written `canonical` string — and both suites re-derive it, so a
tampered digest fails on its own.

There is no generator script, by design. If an implementation disagrees with a
vector, one of the two is wrong; find out which before touching this file. A
diff here is a change to the definition of "converged" and should be reviewed as
one, with both suites run.
