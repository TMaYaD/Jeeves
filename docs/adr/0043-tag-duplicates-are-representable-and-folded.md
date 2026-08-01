# 0043 — Tag duplicates are representable, and folded by `MIN(id)`

**Status:** accepted (2026-08-01)

A Tag's user-facing identity is `(name, type)`, but its op-log identity is a
client-random UUIDv4 — `sync/ids.dart` names Tags explicitly among the collections
that must *not* derive their ids, and only junctions and `user_preferences` are
exempted. Two devices that each create "Alice"/`person` offline therefore fork
into two entities by design, and since People are `Tag(type='person')`, every
person a user adds on two devices takes that path. Reduced state holds both, so
`tags` — a projection of reduced state — must be able to hold both. It could not:
the table declared `UNIQUE (name, type)` (documented, wrongly, as a "test-only
tripwire"), so `DomainProjector`'s id-addressed `INSERT` raised
`SqliteException(2067)` out of `SyncClient.pull()`. Because projection is the
batch tail, that rolled back **every** entity in the batch — after each op was
already durable and the cursor had already advanced. The read model kept a
permanent hole that no later pull would fill, since the next `affected` set no
longer named those entities.

**The constraint is dropped, and `(name, type)` becomes an eventual invariant with
a convergence rule instead of a schema one.** It is enforced locally by
`TagDao.findOrCreateTag`, which every creation path funnels through, and converged
across devices by a `DomainReconciler` that runs at the two projection batch tails
— `SyncClient.pull()` and `rebuildDomainFromOpLog` — and authors real ops. It has
two passes with independent detection queries: a **fold** that collapses each
duplicate group onto the survivor, and a **rehome** that repoints junction rows
whose `tag_id` has no row in `tags`. Not from `project()` itself: the ops these
passes author re-enter projection through the capture seam, so a reconcile inside
the projector recurses. The projector stays a pure function of reduced state,
which is where its order-independence comes from; it materialises, and this
decides. Note the asymmetry with `user_preferences`, whose `UNIQUE (user_id, key)`
stays: its entity id *is* derived from `(workspace, key)`, so two devices writing
one preference are two writes to one entity and can never fork.

**The survivor is lexicographic `MIN(id)` over the group and nothing else** — a
join over entity ids, so commutative, associative and idempotent (ADR-0030), which
is what lets two devices reach the same verdict from different subsets. The
retired ranking (most `todo_tags` references, `MIN(id)` only as a tiebreak) was
unreachable behind the constraint and would have become catastrophic the moment it
was dropped: reference counts are per-device, so two devices folding concurrently
pick different survivors, each tombstones the other's, both tombstones land, and
**both Tags die**. The second pass exists because the fold's own condition is not
durable: a device folding from a partial view can strand a junction on a tag that
another device has since tombstoned, and the group is then `COUNT = 1` — invisible
to any duplicate-based trigger, and a silently-lost Tag assignment rather than a
loud failure. "A junction references a tag that is not there" survives that state,
so it re-fires each reconcile until tag state converges. Recovering the dead
entity's last-asserted `(name, type)` needs reduced state
(`CollectionView.readEntityIncludingHidden`), which gives a domain-level repair a
read into the sync substrate — a deliberately widened seam, accepted because the
pair is recoverable nowhere else. A junction whose pair is unrecoverable, or for
which no live tag holds it, is left as the dangling reference the projector already
tolerates; inventing a delete for it would destroy data to tidy a read model.

The rejected alternative worth recording is **keeping the constraint and having the
projector resolve the conflict** — `ON CONFLICT` with a `MIN(id)` tie-break. It is
order-independent, but the loser then has no row, so the fold's detection query
sees nothing and the loser's junctions orphan for ever; and repointing inside the
projector cannot work either, because the junction entity in reduced state still
asserts the loser's `tag_id` and the next pass re-inserts it. That is churn, not
convergence. The fold must author ops, so the duplicate must be representable.
`INSERT OR IGNORE` was rejected as exactly the silent divergence the defect
warns against, deriving `Tag.id` from `(name, type)` is forbidden outright by
`sync/ids.dart` (and is only a mitigation, since a rename keeps the id), and
retiring the fold machinery leaves the user staring at two "Alice" rows for ever.

Two consequences. The schema change is a one-way v2→v3 recreate, which also
**gates the one forced re-projection that repairs holes existing devices already
hold** (ADR-0035 left the domain store disposable precisely so this is cheap).
And dropping the constraint removes a live footgun: `TagDao.upsertTag` uses
`INSERT OR REPLACE`, which under a `UNIQUE (name, type)` index resolved a name
collision by *deleting* the other tag row — silently, with foreign-key enforcement
off (#637).
