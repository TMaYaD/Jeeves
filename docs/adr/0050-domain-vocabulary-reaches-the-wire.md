# ADR-0050: The domain vocabulary reaches the wire

**Status:** Accepted (2026-08-08, epic #715). Constrains #716 and #717.

The code calls an Outcome a `Todo` in some places and a `Task` in others, and those
legacy nouns are not only local: they appear in twelve wire collection names and in
six derived-entity-id URIs such as `jeeves://todo_tag/$todoId/$tagId`. A derived-id
URI is not a label — the string is hashed into the entity's identity — so changing
one re-mints every affected row's id, and a device that has renamed derives a
different id for the same pair than a device that has not.

**We rename them anyway, up to and including the wire.** The alternative was to keep
the legacy nouns on the wire for good and translate at the reducer, which reads
cheaper and is worse: it makes the mismatch permanent and pays for it with a
standing old-vs-new branch in the merge path — the one kind of arm this codebase
does not carry. A wrong name on an append-only log is a trap that springs whenever
someone reasons about the wire from the domain model, and it gets deeper with every
collection added. The cost of renaming is paid once; the cost of not renaming is
paid by every future reader.

Migration is in-app and needs nothing from the user. Reduction is
collection-generic and only projection is not, so an op naming a retired
collection still reduces and simply has no typed row to become
(`domain_projector.dart`) — retiring a name is the path this codebase already
takes for a collection a build does not know, not a new branch. Ops under the old
names therefore go inert on upgrade, and a one-time re-author pass — the
initial-upload walk, which already transforms every domain row into the op fields
it will carry and authors through the production path, idempotent by diff against
reduced state — re-mints them under the new vocabulary. Nothing is exported, wiped
or re-imported; that path exists but requires the user to perform it and is a last
resort, not the plan.

Two prices are accepted. The old ops stay in the log as dead weight until
compaction prunes them. And during a mixed-version window a device that has not
upgraded keeps authoring under the old names, so its writes are invisible to one
that has, until it upgrades — ordinary contract skew under ADR-0039, bounded by
the upgrade rather than permanent. Local table and column names are not part of
this at all: `codec.table` feeds only local SQL while `codec.collection` is the
wire name, and they are already separate fields, so storage renames are ordinary
migrations.
