# Single current Action with optional planned queue, no auto-promotion

An Outcome's engageable-now Actions can be modelled three ways: 0..1 (sequential-only, GTD purist), 0..N (parallel projects, OmniFocus-style with a `mode` flag), or 0..1-current plus N planned with explicit promotion (queued thinking).

We chose the third: 0..1 current Action per Outcome plus a planned queue. Promotion from `planned` to `current` is an explicit clarifying act — never automatic. Planned Actions are not engageable (no TimeLogs, do not surface in Next / Focus Mode / a FocusSession's Plan); they are visible only in the Outcome's own detail view.

Single current preserves the GTD discipline that "what is THE next physical thing?" forces clarity. The planned queue gets future-action thinking out of the user's head — meeting GTD's "don't leave thoughts in the head" goal — without inviting waterfall planning, dependency graphs (DAGs), or queue-tetris. No auto-promotion keeps each transition a deliberate clarification act, not procedure: when the current Action terminates, the Outcome enters the no-current-Action state until the user explicitly re-clarifies. 0..1 → 0..N is strictly forward-compatible if lived experience ever justifies parallel-project semantics; the reverse would require destructive schema changes.
