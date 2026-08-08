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

The accepted price is that existing op-log history cannot be reinterpreted under
the new names. A device already authoring on the op log takes **export → upgrade →
wipe → import**: because an import authors an op per row through the same seam
every DAO writes through (ADR-0047), every row is re-authored under the new
vocabulary. That preserves everything the user has, and discards that device's op
history — which is evidence, not data, and is the honest thing to spend here rather
than a permanent branch. Local table and column names are not part of this cost:
`codec.table` feeds only local SQL while `codec.collection` is the wire name, and
they are already separate fields, so storage renames are ordinary migrations.
