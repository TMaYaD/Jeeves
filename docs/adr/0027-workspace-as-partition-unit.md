# ADR-0027: Workspace is the partition unit — a complete GTD system, not a shard

**Status:** Accepted
**Date:** 2026-07-27
**Context:** ADR-0026 (Minimal Sync Server), ADR-0025 (Area is exclusive). Vocabulary in `CONTEXT.md` § Workspace.

## Decision

**The unit of key, partition, ordering, and access grant is the Workspace — and a Workspace is a complete, isolated GTD system**: its own Inbox, Areas, Next List, and Plan, analogous to Allen's separate office and home workstations. One per User today, designed for several. Access is granted per Workspace, which is what lets a User expose one Workspace to an AI Service while keeping another private. `user_preferences` lives in an implicit User-global Workspace granted to every Device and no Service, so preferences can never leak through an AI grant.

**Area was rejected as the partition unit** despite being the user-meaningful grouping, for reasons cardinality fixes couldn't cure: Captures have no Area by definition, so every clarification would cross an encryption boundary on the app's main path; a day's Plan spans Areas by construction; and re-Areaing an Outcome is Organising — defined as the cheap, non-stamping act — which partition-by-Area would turn into decrypt → re-encrypt → republish → tombstone. Area is Conceptual tier; the partition unit is Implementation tier; collapsing them loads a paper-GTD concept with key-management weight. Instead, Workspace sits *above* Area (1:many, with Area exclusive per ADR-0025), and everything Area-less sits directly in its Workspace.

**Isolation is a property of storage and membership, not of the User's view.** Devices hold every key their User holds and may render across Workspaces (a unified "today" is a client-side union of per-Workspace FocusSessions); a Service holding one key resolves foreign references as *elsewhere*. Enforcing isolation in the UI would constrain the one party it is not meant to constrain. Two corollaries are load-bearing: a Capture always lands in the current Workspace unprompted (capture never asks a question; relocation is a clarification verdict, mechanically copy + re-encrypt + tombstone, never an `UPDATE` of a partition column), and human collaboration is **delegation over co-ownership** (copy the Outcome into the recipient's Workspace, keep a PersonBlocker and Waiting For on the sender's side) because a Workspace's stance fields — Intent, Plan, clarification stamps — are one mind's and have no shared meaning.

## Trade-off

Multiple Workspaces multiply ceremony surfaces (per-Workspace Inbox and Plan) and put cross-Workspace moves on the expensive path deliberately. We accept both: the moves are rare and deserve weight ("let the AI see Health" merits a confirmation), and the single-Workspace default hides all of it until partitioning ships.
