# ADR-0034: Sync starts at enrolment; the flip keeps the projector-fed legacy store until the prune

**Status:** Accepted (2026-07-30, issue #591, epic #545)

**Context.** Phase 3 of #553 was planned as a staged cutover: reseed the store by
hand from a tooling screen, verify it, stage the server read-only, rehearse a
rollback, then flip. The decision recorded on #553 replaced that with a much
smaller claim — offline-first *is* the rollback story. The phone holds every row
regardless of what the server thinks, and the user's own cutover is a fresh
sign-up, which leaves the previous account and its mirrored tables untouched. What
remained to build was the minimal flip.

**Decision, first half: enrolment authors the local store, automatically, with no
verification gate.** The #587 walk-and-author machinery re-homes out of cutover
tooling into `app/lib/sync/initial_upload_plan.dart` and `initial_upload.dart`, and
`SyncLifecycle.activate` triggers it — the same closure the app runs at every
launch, so an interrupted pass resumes on the next sync rather than needing a
person. A per-account marker in the sync store records a *completed* pass;
absence is the retry condition, and the #587 diff-driven skip makes the retry
free. Verification stays reachable from the cutover screen, but nobody is required
to run it: signing up for sync starts syncing.

We considered keeping a gate — author, verify, then flip. It was rejected because
the gate has no honest failure action. The verification compares the plan against
what the spine reduces back; if they disagree, the answer is a bug fix, not a
user decision, and the phone still holds the data either way. A gate would have
bought a ceremony rather than a safety property. The reversal cost is real and
one-directional: once accounts have enrolled, un-ringing auto-upload means data is
already in logs. That is the trade we are taking, and the reason it is written
down.

**Decision, second half: the domain read model stays the PowerSync-managed store
file, and the legacy connector is disconnected in the same change.** The read
model is now maintained by the spine — DAO writes describe their effects through
`WorkspaceRoutingOpCapture`, and `DomainProjector` writes reduced state back into
the same tables — but the *file* is still PowerSync's. The fresh-store swap to
`jeeves_domain.sqlite` stays with #556, where the engine is deleted.

Disconnecting the connector is required rather than tidy. `_handleMigration` on a
fresh sign-up reassigns every local row to the new account, which enqueues all of
them in `ps_crud`; a connected engine would then upload the entire migrated store
into the new account's legacy tables — a second live sync path beside the op log,
into tables #556 deletes. Two consequences are accepted and named here so a future
reader does not read them as bugs. First, **`ps_crud` grows with nothing draining
it**: local writes enqueue because the tables are PowerSync-managed, which cannot
be turned off without the store swap, and the cost is disk on one device over the
confidence window. Second, a **signed-in but un-enrolled device no longer
replicates at all** — that is what the flip is, and it does not touch local
function.

Pulling #556's store swap forward was the genuine alternative. It was rejected
because nothing in this slice needs it: the projector already writes these tables
correctly (ADR-0010's view-notify discipline exists for exactly that), the reseed
round-trip proved the pipeline over this store, and bolting a write-once store
rebuild onto the highest-risk change of the cutover trades a bounded, documented
cost for an unbounded one.

Relates to ADR-0026 (the op log replaces PowerSync), ADR-0028 (the signed control
plane), ADR-0029 (independent server versioning — this is the change that mints
`server/v0.1.0`), ADR-0030 (the dead `todos.time_spent_minutes` cache and the
dead-letter table both park until the prune), and ADR-0025 (the Area-exclusivity
resolution the transform applies, whose worklist is the next Weekly Review's).
