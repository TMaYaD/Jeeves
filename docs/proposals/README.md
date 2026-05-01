# Proposals

Design proposals for non-trivial changes — domain models, architectural shifts, cross-cutting UX rethinks. Each proposal captures *why* a direction was chosen and the alternatives considered, so future contributors (and agents) don't relitigate settled ground.

Proposals live in-repo (not in the wiki) so they travel with the code's git history, get PR review, and stay grep-able from the working tree.

## Lifecycle

Each proposal carries a `Status:` line at the top. Conventional values:

- **Draft** — under active discussion, not yet decided.
- **Accepted** — direction agreed; implementation may be in progress or queued.
- **Implemented** — landed in code. Proposal is now historical context.
- **Superseded by [link]** — replaced by a later proposal. Keep the file; do not delete.
- **Rejected** — explored and declined. Keep for the reasoning.

When a proposal is superseded or rejected, update the `Status:` line and add a one-line "Why" — never delete.

## Index

| Proposal | Status | Tracking |
|----------|--------|----------|
| [Blockers and Contexts](blockers-and-contexts.md) | Accepted — engineering | [#181](https://github.com/TMaYaD/Jeeves/issues/181) |
