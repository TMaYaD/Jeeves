# ADR-0030 — Non-LWW merge strategies must be join-semilattices; caches are derived, not synced

## Status

Accepted.

## Context

Field-grain last-write-wins is order-independent for free: "apply iff the
incoming HLC is strictly greater" gives the same reduced state whatever order
the ops arrive in, which is what lets a device bootstrap by replaying the log
from zero and get byte-identical state to a device that has been online all
along. ADR-0011 introduced a per-key Conflict Strategy registry for
`user_preferences` — a snooze floor arbitrates by the later *value*, not the
later write — and #550 plugs that registry into the op-log reducer. The moment a
field stops being plain LWW, order-independence stops being free and becomes
something the strategy has to earn.

## Decision

**(a) Every strategy is a join-semilattice.** Any per-key or per-collection
strategy plugged into the reducer must be commutative, associative and
idempotent over `(value, clock)` pairs. This is the property that keeps
reduction order-independent, and #555's compaction correctness leans on the same
one: a compaction op re-asserts values under their original clocks, which is
only safe if re-applying a value the store already holds is a no-op. A strategy
that cannot be stated as a join does not belong in the reducer.

**(b) `maxTimestampValue`'s value join is a total order on the value alone** —
sort key `(parseable?, parsed instant, canonical value bytes)`, winner = max.
Any parseable timestamp beats any unparseable value; among parseable values the
later instant wins; ties on the instant, and the all-unparseable case, fall to
the greater canonical JSON encoding byte-wise. The **clock joins independently**
as `max` under HLC order, whichever value won, so the stored clock may belong to
the losing write. Value and clock decouple deliberately: tombstone visibility is
decided by comparing field clocks against the tombstone's, and keeping that
comparison plain-HLC is what makes clear-versus-re-snooze behave the way a user
expects. The two rejected alternatives both broke the lattice — an LWW fallback
for unparseable values is not associative (three writes reduce differently
depending on which pair meets first), and a clock-based tie-break makes the
value join depend on the clock join, which is the same failure by another route.

This carries **one deliberate divergence from ADR-0011's pairwise matrix**:
because the value max ranges over every value ever asserted, a clear followed by
an **earlier-valued** re-snooze revives the field at the pre-clear floor rather
than the smaller re-snoozed value. The floor can never shrink through a clear.
We accept it because it errs toward longer silence and can never re-fire a
notification early — the failure mode it forecloses is the one that actually
harms the user. It is pinned by
`max_timestamp_value_clear_then_earlier_resnooze_keeps_preclear_floor` in
`spec/sync/reducer_v1_vectors.json`, alongside permutation-flagged three-op
sequences that would catch any regression back to a non-associative join.

**(c) Denormalised caches are never merged.** A cache is derived, so the honest
way to reconcile it is to recompute it from its source collection, not to
arbitrate two copies. The one existing column, `todos.time_spent_minutes`, is
already dead — nothing has written it since the `transitionState` recompute was
retired, and time-spent is derived from `SUM(time_logs)` at read time with open
logs valued at `now()` (#480). So it is excluded from capture, from reduction,
and from projection: recomputing it during projection would buy nondeterminism
(the open-log-at-`now()` term) for a column nothing reads, and it is excluded
from every cross-device equality assertion. Its retirement — the actual column
drop — rides #556 with the PowerSync removal.

## Consequences

The strategy registry stays small and auditable, and adding a strategy is a
design act with a stated proof obligation rather than a switch case. The cost is
that some intuitive rules are unavailable: "prefer the newer write unless the
value is unparseable" cannot be expressed, because it is not associative. Where
a rule genuinely needs write-order semantics, the answer is a different field
(or a different entity), not a non-lattice strategy.

This references ADR-0011 and reframes its client-side arbitration onto the op
log without superseding it: the registry remains the executable source of truth
for which key gets which strategy, and `app/lib/sync/merge_strategy.dart` is a
thin adapter onto it.
