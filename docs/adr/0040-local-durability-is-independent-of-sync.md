# ADR-0040: Local durability is independent of sync, and the server is never a recovery path

**Status:** Accepted (#534). Closes the #525 alpha-window exception going forward.
Constrains #627.

## Context

A Device holds two stores. `jeeves_domain.sqlite` is the domain read model, and
it is disposable *once enrolled* — the Device's own op log can reproject it,
which is the property the cut-over to a Drift-owned store relied on. `jeeves_sync.sqlite` holds the op log, the
outbox, the Quarantine, the Integrity Alarms, the control chain and the Prune
attestations: evidence, plus the only copy of anything authored and not yet
flushed.

The durability hole is a Device that has never enrolled. It has no op log, so
`rebuildDomainFromOpLog` correctly returns without touching anything
(`app/lib/sync/domain_rebuild.dart:32-43`) and the domain store is the only copy
of everything the user has ever written. The PowerSync-era store was discarded
exactly that way once, as a one-time destructive exception the user invoked
deliberately; #525's
`next_action_text` drop then proceeded under an explicit alpha-window assumption
that no such Device exists. Neither is a rule, and the second was flagged as not
being one.

The instincts already in the code are mostly right and inconsistent at the edges.
The sync store declares itself additive-only — "a device that already holds a log
keeps every byte of it" (`app/lib/sync/sync_database.dart:459-461`) — and two of
its steps refuse rather than de-duplicate, on the grounds that the rows are
evidence (`:496-501`, `:519-524`). But the recovery those refusals instruct is
literally `delete and recreate this sync store`, on the one store whose contents
the server may never have seen. Meanwhile the one path that does wipe is the safe
one: `rebuildFromOpLog` deletes derived reduced state only and replays the local
log (`app/lib/sync/sync_client.dart:1153-1159`), never a download.

## Decision

**Sync is a replication mechanism, not a correctness dependency.** A Device that
has never enrolled, or has been offline for arbitrarily long, keeps every row it
ever wrote and keeps working — the guarantee is against sync being unavailable,
it does not degrade with time since the last successful pull, and no feature may
condition correctness on having synced. It is not a promise the app always opens:
an incompatible migration still wedges the affected store (see Trade-off), and
what holds in that case is the retention half.

**A client schema change must carry its own data forward locally.** It may not
rely on a server-side backfill, a re-download, or an Initial Upload having
happened, to reconstitute anything. The test is not "does a server copy usually
exist" but "could this store hold the only copy" — and for a never-enrolled
Device, or for ops still sitting in an unflushed outbox, the answer is always
yes. A migration plan whose recovery step is "re-download it" has made sync a
correctness dependency, which is the thing this decision forbids.

**Discarding a store and reconstructing it from the server is never a remedy for
data the server has never seen.** The only sanctioned rebuild is the domain read
model of an enrolled Device, reprojected from that Device's own local op log —
local replay, not a fetch. `jeeves_sync.sqlite` is never a candidate: it holds
evidence and unflushed authorship, and both are irreplaceable by definition. The
"delete and recreate this sync store" recovery the refusing migrations currently
name is therefore wrong as stated and has to become a path that preserves the
bytes — #636 tracks that replacement, and until it lands the destructive
instruction is still what those migrations tell the user. (Note also that
"reseed" is retired vocabulary — it named a cutover verification surface that no
longer exists — so the ruled-out operation is described here as what it is rather
than under that name.)

**No schema change on either side may assume a bounded client-version spread.**
Backend migrations stay additive and non-destructive; client schema steps must be
applicable by a Device that jumps arbitrarily many versions in one upgrade, which
is why the sync store's steps are sequential `if (from < n)` rather than exclusive
branches. A client change must never require a particular backend deploy to have
landed first — that is ADR-0039's rule restated for schema, and the two decisions
are the same claim seen from two ends.

**A change that cannot preserve the data refuses, and leaves the bytes intact for
a compatible client or recovery tool.**
Refusing is the correct instinct and is already in the code; what refusal may not
do is hand the user a destructive instruction as its only way out. That earlier
drop stands as a one-time, user-invoked event and is explicitly not a template
for the next one.

## Trade-off

**This makes some schema changes materially harder, and a few impossible as
designed.** A change needing data the local store cannot derive can no longer
ship as drop-and-refetch; it either carries the data forward or does not happen.
That is the cost of the guarantee, and it is paid mostly by whoever wants to
remove a column — precisely the change that looks free and is not.

**A refusing migration wedges the app for the affected store until a fix ships.**
That is accepted over the alternative, which is opening silently on a store that
has quietly lost rows. It does mean a migration refusal is a release-blocking bug
class rather than a graceful degradation, and its message is user-facing surface
that must offer a non-destructive route.

**The guarantee is asymmetric between the two stores, and that asymmetry is
load-bearing.** The domain read model is cheap to rebuild because it is derived;
the sync store is not, because it is the record. Reading "disposable
by construction" as a property of local storage generally, rather than of a
projection over an existing log, is the specific mistake this ADR exists to
prevent. #627 inherits the direct consequence: a pending record for an epoch that
can never publish is marked terminal and retained, never deleted, because
clearing a stuck state by destroying its bytes is the same error at a smaller
scale.
