# ADR-0038: Prune ops carry per-op chain attestations, not bare seqs

## Status

Accepted (#555).

## Context

The proposal says a prune op "enumerates the seqs its compaction supersedes". That
reads naturally if compaction truncates a prefix — and it does not. Compaction is
**entity-level** (proposal § Compaction and GC), while a per-author chain is
whole-Workspace: an author's chain interleaves every entity it has ever written to.
So pruning one entity's ops removes positions from *inside* every contributing
author's chain, and usually several disjoint runs of them.

That breaks the thing per-author chains exist for (ADR-0026): a fresh device
verifies each op against the previous position of its author's chain by
`prev_author_hash`. Given only transport seqs it cannot verify a survivor at
`author_seq N` at all. It does not know whether `head+1 .. N-1` were legitimately
compacted away or silently withheld by the server — which is the one distinction
the chain is there to make — and even if it took that on trust it has no hash to
check `N`'s link against.

Two alternatives were on the table. A **floor-only** design gives a device one
"verified up to here" marker per author, which bridges a prefix and nothing else;
mid-chain holes are exactly what it cannot express, so the very shape entity-level
compaction produces is the shape it fails on. **Trusting the seqs** and skipping
verification past a hole is worse than it sounds: a server that can persuade a
device to stop checking links over a range it names has been handed the ability to
withhold ops undetectably, which is the property ADR-0026 was written to buy.

## Decision

A prune target is a **four-field attestation** — transport `seq`, the
`author_member_id` and `author_seq` of the position, and the `envelope_hash` that
used to sit there — and clients persist them (`pruned_attestations`). The
verified chain floor is then walked contiguously forward from an author's real
head, filling each step from the log or from one attestation, so every bridged
position is individually accounted for and hash-linked. The floor **wins above the
derived head**, which is the one change #555 makes to shipped verification logic;
below the head the log is the better evidence and still wins.

The cost is real and accepted: a prune is proportional to what it supersedes rather
than constant, and each attestation is ~60 bytes of payload plus a stored row on
every device. That buys three things a bare seq cannot. A fresh device verifies the
chain across the holes instead of trusting them. A device that *kept* the originals
cross-checks the attestations against its own `op_log` and can catch a lying
compactor — the only party that can, since a fresh device necessarily trusts the
compactor's signature, which is what the "most trusted" reading of the `compactor`
role means. And the **server** can check all four fields before it stamps anything,
because it holds the envelopes; a forged attestation would poison the chain
verification of every fresh device that later trusted it, so refusing it at the door
is the only place the check is both possible and cheap.

Being server-checkable is why the payload stays `plaintext_v1` for ever
(`encrypted_prune_op`), which is the second deliberate exception to the server's
content-blindness after control ops (ADR-0028). It concedes nothing: the
enumeration names positions and hashes the server already holds and says nothing
about what any op contained.

## Consequences

- The wire format is frozen in `spec/sync/envelope_v1_vectors.json`, so this is
  hard to revisit: a v2 prune would have to be a new op class or a new suite.
- Compaction pays for itself less quickly than a prefix truncation would. That is
  the honest price of entity-level granularity, which was chosen so a hot entity
  can be compacted without rewriting a whole Workspace snapshot.
- A prune being judged must also bridge with its **own** enumeration, because in
  the v1 shape the owner device self-compacts and its prune therefore sits above the
  holes it attests. Judged against stored attestations alone it would be an
  `author_chain_gap` for ever and nothing would ever apply it to create them.
- Attestations and evidence can disagree, so there is a new accusation
  (`prune_attestation_divergence`) and it never heals: both sides bear real
  signatures, so either the author forked its own chain or the compactor attested a
  fabrication, and neither is something a receiver may quietly resolve.
- Prunes are exempt from being pruned. A prune *is* the attestation that history was
  removed; losing it would leave garbage collection indistinguishable from a server
  that truncated the log, which is the same reasoning that exempts control ops.

Builds on ADR-0026 (the op log and its per-author chains) and ADR-0030 (merge
strategies as join-semilattices, which is what makes a compaction snapshot
absorbable rather than a fresh write).
