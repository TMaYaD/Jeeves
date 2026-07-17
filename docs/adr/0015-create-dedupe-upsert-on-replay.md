# 0015 — Create-dedupe routes upsert on same-user replay

## Status

Accepted.

## Context

Every connector-facing POST create route dedupes on the client-generated `id`
so PowerSync's at-least-once upload is idempotent (`create_todo`, `create_tag`,
`create_focus_session`, `create_time_log`, `create_user_preference`,
`create_capture`). Historically a same-user id match returned the **stored row
verbatim**, discarding any fields in the replayed payload; `create_capture`
(PR #422) instead field-compared and `409`ed on any mismatch.

The divergence window (docs/SYNC.md window 3): the connector-facing POST create
persists the row server-side, but its ack is lost mid-sync, so PowerSync still
holds the create in its upload queue. The user edits the row offline; because
the create was never confirmed, PowerSync consolidates that edit into the
still-queued create and retries it as a single POST. The replayed POST now
carries **newer** data than the stored row. The return-stale routes silently
drop it and the next checkpoint download overwrites the newer local values; the
`409` route dead-letters the entry (losing the same data and wedging
diagnostics). Either way a legitimate offline edit is lost — by construction,
because any 4xx on a legitimate replay dead-letters and return-stale reverts one
checkpoint later.

## Decision

**Upsert-on-replay.** When the `id` already exists for the **same user**, apply
the submitted client-owned fields to the stored row and return it (2xx), so a
consolidated replay converges the server row. A cross-user id collision stays a
`409` (a genuine anomaly, not a replay).

Two constraints make this safe:

- **Apply only fields the client actually sent** — `model_dump(exclude_unset=True)`,
  with the dedupe key `id` (and, on todos, the junction-owned `tags` and the
  legacy `state`) popped, and server-owned `user_id` never touched. An omitted
  field is left as stored, which preserves the #380 guard
  (`test_create_idempotent_retry_keeps_clarified`: a retry that omits
  `clarified` must not flip the stored `false` to the schema default `true`).
  The connector always sends the full row, so real convergence still happens;
  direct-REST partial retries stay safe.
- **Junction routes are out of scope and unchanged.** `todo_tags`,
  `capture_outcomes`, `capture_tags`, and `focus_session_tasks` keep their
  relation-mismatch `409` — the same id for a different `(parent, child)`
  relation is a real anomaly, and their rows are immutable-or-nearly-so.
  Tag-set convergence for a todo flows through `todo_tags`, not `create_todo`.

Strict-compare-`409` (the PR #422 approach) was rejected: it violates the
permissive-routes policy (SYNC.md window 3 — keep routes idempotent/permissive
so a legitimate write never 4xxs) and dead-letters the exact data it should
converge. Upsert also beats return-stale, which reverts the edit one checkpoint
download later.

## Consequences

The interaction with ADR-0011 is benign: the per-key conflict strategies
arbitrate client-side download reconciliation, while the server POST route is
already last-arrival for the row it owns; upserting the submitted value on
replay changes nothing the registry depends on.

**Accepted trade-off — an explicit product decision, not an open question.** The
upsert is unconditional (no server-side revision or last-write-wins guard), so it
is *not* strictly conflict-free: a device-A create-replay arriving after a
device-B PATCH of the same row will regress B's edit, because the replay carries
A's pre-PATCH values. **We accept this loss deliberately.** It is the same
last-arrival semantics the entire backend already commits to — the PATCH routes
overwrite unconditionally too, so a create-replay is not special — and any
alternative that rejects the write (4xx) dead-letters a legitimate offline edit,
which window 3 forbids. Server-side revision/ordering protection is explicitly
out of scope: it would require a monotonic server revision column plus
conflict-reconciliation UI the product does not have (tracked as the same
follow-up as the `user_preferences` two-sided conflict interface), and it trades
a narrow, self-healing cross-device race for a heavier mechanism.

The strictly-safer client-timestamp variant was considered and **declined**:
guard `submitted.updated_at >= stored.updated_at` and, when the guard fails,
degrade to returning the stored row with 2xx (never a 4xx). Declined because it
adds per-route timestamp logic for a narrow cross-device race, is itself only a
partial order (clock skew), and diverges from the uniform last-arrival model — it
stays the recorded escape hatch if the race proves real in practice, but does not
gate this decision.

Related: ADR-0006 (capture split), ADR-0011 (user_preferences conflict
strategies), and the PR #422 permissive-routes discussion
(https://github.com/TMaYaD/Jeeves/pull/422#discussion_r3602300225).
