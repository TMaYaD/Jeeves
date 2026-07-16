# Agent Instructions

Generic instructions for AI agents. Copy-pasteable to any project.

## First Steps

1. **Check the scratchpad** (`SCRATCHPAD.md`) for current goal
2. **Read project documentation:**
   - `README.md` - Project overview
   - `CONTEXT.md` - Domain glossary across bounded contexts; authoritative for vocabulary
   - `docs/adr/` - Architecture Decision Records; check before making architectural changes
   - `docs/REQUIREMENTS.md` - What we're building
   - `docs/ARCHITECTURE.md` - How it's built
   - `docs/TESTING.md` - Testing strategy (+ emulator tap coordinates for manual `adb` testing)
   - `docs/DESIGN.md` - Design system

3. **Update Requirements:** Whenever the user asks for new requirements, update `docs/REQUIREMENTS.md` for future reference. When new domain concepts arise, update `CONTEXT.md`. When you make a decision that meets the ADR three-criteria filter (see below), write an ADR.
4. **Re-read specs every 30 minutes** or when uncertain. Requirements drift causes wasted work.

## Domain Vocabulary (`CONTEXT.md`)

`CONTEXT.md` is the source of truth for domain terms. It is organised into two top-level tiers (Conceptual / Implementation) with bounded contexts nested where they have grown large enough to warrant grouping.

- **Use CONTEXT.md vocabulary verbatim** in code, docs, commit messages, PR descriptions, UI copy.
- **Code and user-facing copy use the same terms.** Any divergence between code identifiers and UI labels needs a specific reason (cadence-flavour, established vernacular, accessibility) and an unambiguous mapping recorded in the relevant term's definition or Flagged ambiguities.
- **New concepts the user thinks about** → add to the Conceptual tier first, then implement. The model can run ahead of the implementation; that is by design.
- **Code conflicts with the conceptual model** → log under that context's Flagged ambiguities. Do not silently paper over a mismatch — the ambiguities list is the punch list for reconciliation work.
- **CONTEXT.md describes the current conceptual state.** Treat it the same as `docs/`: not a changelog. Rewrite affected sections when the model changes; remove statements that are no longer true.

## Architecture Decision Records (`docs/adr/`)

ADRs preserve the reasoning behind decisions that future contributors would otherwise re-litigate blind.

- **Before architectural changes:** scan `docs/adr/` for prior decisions that might apply or constrain. An ADR represents a deliberate choice, not a default.
- **Write a new ADR** when a decision meets all three criteria:
  1. Hard to reverse — the cost of changing your mind later is meaningful
  2. Surprising without context — a future reader would wonder "why on earth did they do it this way?"
  3. The result of a real trade-off — there were genuine alternatives picked for specific reasons
- **Filename:** `docs/adr/NNNN-slug.md`, sequential numbering (scan the directory for the highest existing number and increment by one).
- **Length:** typically 1–3 paragraphs. Record *that* a decision was made and *why* — not how to implement it. An ADR can be a single paragraph.
- **ADRs are not changelogs.** If a later decision supersedes an earlier one, the earlier ADR stays in place and the newer one references it.

## Development Methodology: TDD (Top-Down)

Follow this order strictly:

### 1. Write E2E Tests First
Start with end-to-end tests that verify complete user journeys.

```
Before building a feature:
→ Write test that exercises the full user flow
→ Test fails (feature doesn't exist)
→ Now implement
```

### 2. Write Integration Tests Second
Test component interactions at boundaries.

### 3. Write Unit Tests Third
Test pure business logic in isolation.

### 4. Implement Code
Make tests pass with minimal code.

### 5. Refactor
Clean up while keeping tests green.

### 6. Check for Regressions
Run full test suite before considering work complete.

## Code Principles

### Structure
- Flat, explicit code over abstractions
- Group by feature, not layer
- Minimize coupling between files

### Testing
- **Test real behavior only** - no mocks for system components
- If it can't be tested as it runs in production, redesign it

### Quality
- Run linter/analyzer before commits
- Run full test suite before commits
- Run full test suite before commits
- No incomplete or unverified work

### Data Persistence
- **Always maintain data integrity**. Schema changes must not result in data loss for the user.
- **Use proper migrations**. Write specific migration scripts to handle schema evolution.
- **NEVER use destructive migrations**. Do not drop tables or perform operations which result in data loss. The user values their data.

### Bounded Context Discipline
- If `CONTEXT.md` defines bounded contexts, treat them as vocabulary boundaries — types and concepts from one context should not leak into another's function signatures or domain logic.
- **Cross-context dependencies flow in the direction `CONTEXT.md` prescribes** — typically infrastructure or augmentation contexts depend on the core domain, never the reverse. A core-domain function signature referencing an infrastructure-context type is the warning sign.
- When implementation lags the conceptual model (Conceptual-tier terms with no Implementation backing), the gap is recorded in Flagged ambiguities, not papered over with shortcut types.

## Versioning Policy (CRITICAL)

Strictly follow Semantic Versioning.

## Workflow

1. **Understand** - Read docs, understand the task
2. **Test** - Write failing test defining expected behavior
3. **Implement** - Make test pass
4. **Refactor** - Clean up, tests still pass
5. **Verify** - Full test suite, build check
6. **Update scratchpad** - Mark goal done, set next goal

## Creating GitHub Issues

All issues must follow the project's issue template (`.github/ISSUE_TEMPLATE/`).
The GitHub UI enforces this on humans; agents creating issues via the API must
match it manually.

Required sections, in order:

- **User Story** — `As a <persona>, I want <capability>, so I can <outcome>.`
- **Scope** — bullet list of what's in scope.
- **Acceptance Criteria** — checkbox list of testable conditions.

Optional sections (include when they add value):

- **Out of Scope** — what is explicitly NOT covered.
- **Related** — linked issues, PRs, docs, proposals.

Do not open issues that skip the required sections.

## Scratchpad (`SCRATCHPAD.md`)

Maintain a scratchpad with:
- **Current Goal** - One bite-sized task you're working on now
- **Next Goals** - Short queue of upcoming tasks
- **Blockers** - Anything preventing progress
- **Notes** - Context that shouldn't be forgotten
- **Last Spec Read** - Timestamp to know when to re-read

Update after completing each goal. Keep goals small (< 30 min each).

## When Stuck

1. Re-read the requirements
2. Check if you're solving the right problem
3. Break into smaller testable pieces
4. Ask for clarification

## File Organization

| File | Purpose | Scope |
|------|---------|-------|
| `AGENTS.md` | Agent instructions | Generic (copy to new projects) |
| `SCRATCHPAD.md` | Current goals, working memory | Session-specific |
| `NOTES.md` | Corrections to agent instincts | Project-specific |
| `README.md` | Project overview | Project-specific |
| `CONTEXT.md` | Domain glossary across bounded contexts | Project-specific |
| `docs/` | Detailed documentation | Project-specific |
| `docs/adr/` | Architecture Decision Records | Project-specific |

Keep AGENTS.md generic. Project details go in README.md, CONTEXT.md, and docs/.

## Documentation in docs/

Files in docs/ (ARCHITECTURE.md, BACKEND_GUIDELINES.md, DESIGN.md, REQUIREMENTS.md, TESTING.md) and the root-level `CONTEXT.md` describe the current state of the project. They are not changelogs. A reader should be able to understand the system today by reading them, without consulting git history, issues, or PRs.
When you change code that affects anything these documents describe, update the relevant document in the same change — not at the end of the session. Treat the docs as part of the code.
When updating:

Rewrite affected sections so they describe the new state. Do not add "Updated X" or "Changed Y" notes.
Remove statements that are no longer true. Stale claims are worse than missing ones.
If scope, goals, or direction changed (not just implementation), update REQUIREMENTS.md or DESIGN.md accordingly.
If you're unsure whether a doc needs updating, read the doc first and check. Don't skip this step.

Git history and GitHub issues are the source of truth for how and why the system got here. The source code is the source of truth for what it is now. /docs is a summary of both.

## Keep Notes (`NOTES.md`)

NOTES.md records corrections to agent instincts: cases where the default, reasonable-looking approach was wrong in this project, and a fresh agent would likely make the same mistake even after reading the code and docs. It is not a changelog, not documentation, and not a work journal.

Before appending, apply two tests:

1. **Fresh-agent test.** Would a capable agent still get this wrong on a first attempt? If the fact is discoverable by reading the code or docs, it belongs there, not here.
2. **Routing test.** A decision with real trade-offs → ADR. A fact about how the system works or is tested → docs/. What a change did and why → the PR description and commit message. Only the wrong instinct itself goes here.

Write the entry as the correction, in one or two lines:

`- <date>: Instinct: X. Here: Y — because Z.`

If an entry can't be phrased that way, it belongs somewhere else. Codebase traps that keep biting (test-harness quirks, framework gotchas) go in the relevant doc — the doc update is mandatory, a NOTES pointer is optional. Don't ask permission; do apply the tests.


