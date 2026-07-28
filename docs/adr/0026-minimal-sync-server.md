# ADR-0026: Minimal Sync Server

**Status:** Accepted
**Date:** 2026-07-27
**Context:** `docs/proposals/minimal-sync-server.md` (the full design) and its adopted adversarial security review.

## Decision

**The sync backend becomes content-blind.** PowerSync and the mirrored PostgreSQL domain schema are replaced by a minimal server that stores and transports opaque, client-encrypted envelopes in an append-only per-Workspace op log, with a server-assigned sequence as the pull cursor. All domain knowledge — schema, reduction, conflict resolution — lives in the client. The server's total vocabulary is Users, Members, Workspaces, Grants, KeyWraps, ops, and the recovery escrow; none of it changes when the domain model does.

The mirror never earned its keep: every sync bucket partitioned on `user_id` alone, yet the server had to understand every column to do it — 13 mirrored tables, 29 migrations, ~700 lines of schemas and ~1,400 lines of routes sustaining one predicate. Worse was the contract it forced (the `docs/SYNC.md` upload contracts, column-ownership matrices, dead-letter machinery, and per-column tripwire tests existed *only* because the server parsed rows — schema drift produced real data-reverting bugs, #380), and the engine behaviour it made untestable (the PowerSync engine cannot run in the Dart harness, so the reconciliation windows were verified only by hand). Meanwhile domain merge already lived client-side (the Conflict Strategy registry, `convergeMultiCurrentActions`): we paid for a smart server that acted as a minimal one. Making it one buys end-to-end encryption as a wrapper change (`plaintext_v1` → `aead_v1` envelopes), makes adding a domain field a client-only change, makes sync testable in-process, and makes AI a *client* holding a granted key rather than a server feature.

## Considered options

**Keep PowerSync over an opaque-row store — including the narrower variant of keeping it only as the download transport for the op log itself.** Rejected, twice over (the narrow variant was SWOT-analysed separately after the design settled):

- *The trust model inverts the transport's job.* PowerSync's contract is that the local table faithfully mirrors server bucket state, which licenses the engine to delete and rewrite local rows (bucket exclusion, checkpoint re-sync). The adopted security review requires the opposite: the client's received log is immutable evidence — per-author chains exist precisely to make server truncation and rollback detectable. Under a bucket filter, `compacted_by` soft-deletes arrive as the transport deleting local ops, making legitimate compaction and malicious truncation indistinguishable at the storage layer. Neutralising that requires copy-on-arrival into a client-owned store, at which point PowerSync is an expensive HTTP GET in front of triple client-side storage (plus a fourth copy in its server-side bucket storage).
- *It keeps the delivery layer permanently untestable.* The engine cannot run in the Dart harness (`docs/SYNC.md` records zero automated coverage of the engine path) — and fixing exactly that is one of this decision's motivations. A `GET ?since=seq` loop over plain tables is testable end-to-end, including the review's normative quarantine/alarm paths.
- The custom transport is small *because the design made it small* — server-assigned seq, idempotent append, client-held cursor is the deliberately easy problem; PowerSync's checkpoint/diffing machinery solves the hard problem the op log eliminates. The genuine losses (hardened download streaming, already-solved web/OPFS storage) are bounded and one-time, and because ops are self-verifying, a dumb replicator can be reintroduced later as pure optimisation — it can never forge, only withhold. Transitional use was also rejected: it is exactly the legacy branching the Implementation stance forbids, and it converts a small server build now into a fleet storage migration later (worse still if E2EE lands first).

**Generic CRDT (Automerge/Loro) with a blob-relay server.** Rejected: immature Dart FFI bindings, and the app's relational query surface (Plans, focus sessions, `SUM(time_logs)`) fits a field-grain op log with client reduction better than a document model.

## Consequences

Ordering and idempotency move to protocol identity (server `seq` is transport-only; hybrid logical clocks order merges; op ids are author-namespaced). Deletion becomes an op — the delete-on-absent hazard class in `docs/SYNC.md` becomes structurally impossible. ADR-0011 and ADR-0015 survive as client-side concerns; ADR-0017 is retired with the sync-rules mechanism it configured. Implementation is clean-slate per the proposal's Implementation stance: legacy behaviour and data are preserved only where ultra-cheap, never at the cost of branching.
