# ADR-0035: The domain store is cut over by fresh file, not migrated

**Status:** accepted (2026-07-30)

The domain read model lived in `jeeves.sqlite`, a file the PowerSync engine
owned: `todos`, `tags`, `actions` and the rest were *views* over its internal
`ps_data__*` tables, with INSTEAD OF triggers doing the actual writing. That
ownership is why the Drift schema had grown a 28-step migration ladder made
mostly of `sqlite_master` guards — `ALTER TABLE` on a view throws, so every step
had to ask whether it was looking at a real table or a view and skip itself in
production. With the op-log spine as the production sync path (ADR-0026,
ADR-0034) the engine has no job left, and the store has to move to a file Drift
owns outright.

**It moves by being created, not converted.** The app opens a new
`jeeves_domain.sqlite`, and on the first open — and every launch after, because
absence is a no-op — deletes `jeeves.sqlite` and its `-wal`/`-shm` sidecars. A
device whose local op log holds reduced state has it projected into the fresh
file through the same `DomainProjector` a pull batch uses; a device with no log
starts empty.

The alternative was an in-place conversion: keep the engine long enough to read
the views once, copy the rows into Drift-owned tables, then drop the engine. It
was rejected on three counts. The conversion code would be a second read path
over a schema we are deleting, correct exactly once and untestable afterwards.
It would keep the engine — and its `ps_crud` queue, its connector and its
credentials route — alive across the one release where the point is that they are
gone. And it would be redundant for the case that actually matters: an enrolled
device's op log already *is* the record, and the domain store is by definition a
projection of it, so replaying the projection is both cheaper and the same
machinery the app runs on every sync.

**The user sanctioned the loss this trades against.** A device that never
enrolled has no log, so its store starts empty and its data is not carried; the
recovery path is a fresh sign-up, the enrolment ceremony, and re-importing from
Nirvana (which now authors ops through the capture seam). That is a one-time
destructive exception to the project's own "never destructive migrations" rule,
invoked deliberately by the user rather than assumed by this decision, and it is
what makes the greenfield cut cheap enough to ship as one flow instead of a
staged carry-over.

Two consequences worth naming. The deletion takes the forensic copy of the
`sync_dead_letters` rows with it — the server-side backup is the backend half's
concern, not this file's. And schema evolution is ordinary again: `schemaVersion`
resets to 1 with `onCreate: createAll()`, and the next change is a normal Drift
`onUpgrade` step, with `ADD COLUMN` and `DROP COLUMN` both working for the first
time since the engine arrived. The column drops the old ladder could not perform
are therefore no longer a one-time opportunity, which is why this ADR does not
bundle any of them.
