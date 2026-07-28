# ADR-0025: Area is exclusive, Label is cross-cutting

**Status:** Accepted
**Date:** 2026-07-27
**Context:** Arose while designing the partition unit for the replacement sync architecture, but stands on its own as a GTD Core model decision.

## Decision

**An Outcome belongs to at most one Area. Labels carry all cross-cutting grouping.** Area answers *where does this live*; Label answers *what else is this about*.

Area and Label were both M:N, which left them distinguished only by convention — one described as GTD canon and "permanent", the other as a Jeeves extension and "free-form". Neither property is enforceable, and nothing stopped a permanent Label or a retired Area, so the boundary was a vibe rather than a rule. Worse, the Label entry already claimed the cross-cutting job ("to cut across Areas"), which made Area's M:N a second, competing mechanism for the same need.

Exclusivity gives the distinction a structure: a thing has one home and any number of annotations. It also makes an Area-by-Area pass **non-overlapping** — no Outcome surfaces under two Areas, so the Areas plus one bucket for the Area-less remainder cover everything exactly once. Under M:N an Outcome in three Areas surfaced three times and no single pass guaranteed coverage, which undercuts the one job Allen actually assigns Areas: reviewing responsibilities to catch neglect.

**This is not a departure from GTD.** Allen specifies Areas of Focus as a horizon-2 concept but establishes no project↔area membership at all — the Projects list is flat, and Areas of Focus is a separate list reviewed for neglect and for generating projects, with the linkage living in the reviewer's head. The previous glossary wording implied canon dictated the cardinality; canon left the question open. Separately, Allen's advice to keep a workstation at the office and another at home is capture infrastructure (GTD ch. 4), not a taxonomy — the organising concept for "where I physically am" is **Context**, which Jeeves already attaches to Actions.

## Considered options

**Keep Area M:N.** Rejected: it duplicates Label's stated purpose, and it makes Area-based review overlapping — the same Outcome surfaces under every Area it holds.

**Collapse Area and Label into one M:N concept.** Rejected: the two questions are genuinely different, and the exclusive one is what a review pass needs.

**Make Area the encryption/sync partition unit directly** (the question that surfaced this ADR). Rejected on its own terms; see ADR on the sync partition. The relevant point here is that it would have inverted Area's cost model — reassigning an Outcome's Area is **Organising**, defined as the cheap, non-stamping act, and it must stay cheap.

## Trade-off

The user must now choose one Area for an Outcome that genuinely serves two — "buy health insurance" is plausibly Health *and* Finance. We accept the forced choice: picking a primary home is a legitimate organising decision — and stays one, non-stamping, even when a Weekly Review pass or a clarification flow is where the user is asked. The escape hatch already exists as a Label.

The migration touches live data and contains a decision only the user can make. Multi-Area Outcomes are resolved by user choice rather than auto-picked, surfaced as a dedicated Weekly Review pass, and the surplus memberships become Labels rather than being dropped — nothing categorised is lost, it only changes which mechanism carries it.
