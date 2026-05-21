# No multi-Outcome Project composition

A "Project" colloquially means a multi-step goal. There are two ways to model it: (a) an Outcome that requires multiple Actions over its lifetime, (b) an Outcome with child Outcomes forming a parent-child tree. Tools like OmniFocus and Things support shape (b).

We use shape (a) only. Project is a derived classification — an Outcome that ends up needing more than one Action — not a separate entity, not a parent of other Outcomes. There is no parent-child Outcome relationship.

Multi-Outcome composition introduces tree semantics (cascade-on-trash, completion propagation, nested permissions, ordered/unordered children) without a concrete use case driving them. The Action lifecycle already carries multi-step Outcomes coherently. Cross-Outcome grouping at higher horizons is served by Areas (recurring responsibility domains) and Labels (granular categorisation), not by Outcome composition. If a concrete need for tree semantics emerges later, adding a parent-child relationship is forward-compatible; the present cost of avoiding it is zero.
