# Plan as commitment, not auto-growing

A FocusSession's Plan is the List of Outcomes selected during Planning. When the user engages off-Plan during the session, the Plan can either stay fixed (commitment) or auto-grow to include the engaged Outcome. Both shapes are coherent and the Review surface ends up identical either way — the difference is only in what "Plan" means.

We chose **commitment**: Plan stays fixed at Planning. Off-Plan engagement is allowed (per ADR-0005) and attributes to the session, but does not modify the Plan. The Plan-vs-actually-engaged set is preserved as two distinct pieces of information.

Planning is a deliberate act — auto-mutating the Plan blurs the line between deliberate selection and ad-hoc engagement. The plan-vs-reality gap is a useful retrospective signal ("I keep planning things I don't do," "I keep getting pulled into off-plan work") that auto-growing destroys at the source. The commitment model is also strictly more information-preserving: the auto-growing view can be derived from the commitment model's data (Plan ∪ engaged), but the original-intent set cannot be recovered from the auto-growing model without an audit trail.
