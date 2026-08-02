# ADR-0047: The data export is the op-log wire encoding, and import detects it silently

**Status:** Accepted. Builds on ADR-0030 (merge strategies / the codec is the wire
contract) and the issue #610 principle that an import must author ops to be seen; extends
Epic 11 (Data Portability) with the export half.

## Context

Two ways to give the app a data export presented themselves.

The obvious one is a bespoke export schema — a document shaped for a human or for some
interchange standard, with its own field names, its own date format, its own notion of what
a "task" is. It reads well and it is independent of storage internals. Its cost is a second
serialisation that has to be kept in step with the domain model for ever, and a re-import
path that has to translate that shape back into the eleven domain tables by hand, deciding
per field how to reconcile it with whatever is already there.

The app already has a single canonical serialisation of every domain row: the op-log wire
encoding in `sync/collection_codecs.dart`, which sync, the initial-upload walk, and the
projector all speak. It is the one place that answers "which columns of this collection
travel, and how is each value spelled." A `dateTime` is `encodeInstant`'d; a TEXT timestamp
passes through; bool/int/text are JSON natives.

## Decision

**The export format is the op-log wire encoding, and nothing else.** An export is
`{"jeeves_export": <version>, "collections": {<collection>: [<row>, …]}}`, where each row
is exactly what `collection_codecs.dart` would put on the wire, `id` included. The exporter
walks every syncable collection **except `user_preferences`** — GTD data only, never
preferences, and never any credential (auth material is not in the domain database at all)
— filtered to the current user.

Because the format *is* the wire encoding, the importer replays each row straight back
through the seam every DAO writes through: it writes the local row **and** authors the op,
inside `capturing` scopes, so an imported export syncs to the user's other devices exactly
as a Nirvana import does (issue #610), and works fully offline on an un-enrolled device
where the op is simply dropped. There is no second serialisation to drift, and no bespoke
reconciliation: a re-import is idempotent because the row ids are the export's own, so it
lands on the same rows the codec-driven upsert already knows how to locate (owned entities
by `id`, junctions by their domain pair — the same rule the projector uses). The
export→import→export round-trip is byte-identical.

**Import detects the format silently.** The single import entry point sniffs the file's
envelope and routes a Jeeves export to the Jeeves importer; a Nirvana JSON export is a bare
list and can never carry the envelope, so the two cannot be confused. No UI or copy names
the second format, or the fact that the app can export at all — the requirement was that
import support the export with no visible change, and the sniff is what delivers it. The
export UI itself is reached only through a hidden developer-options Easter egg (seven taps
on the Jeeves name in About), so the feature ships without advertising itself anywhere a
user would stumble on it.

## Consequences

The export is now a **compatibility surface**: once a user holds an export file, the wire
encoding it captured has to remain readable. This is the same contract sync already lives
under — the codecs were already frozen protocol — so the export adds no new frozen surface,
only a new *holder* of the existing one. The `jeeves_export` version field exists for a
genuinely breaking change to the envelope shape; an additive column needs no bump, because
the importer asserts only the columns a row carries and ignores unknown ones.

`user_id` is remapped to the importing account on every row, so an export is portable
across accounts, not merely a same-account backup. The cost is that importing *your own*
already-synced export re-authors ops for entities that already exist — harmless, because
those ops are idempotent re-assertions the reducer folds away, but real write traffic.

Excluding `user_preferences` is a deliberate scope line, not an oversight: preferences and
credentials are explicitly out of what a GTD-data export carries. If a preferences export
is ever wanted, it is a separate decision with its own privacy weighing, not a column added
to this walk.
