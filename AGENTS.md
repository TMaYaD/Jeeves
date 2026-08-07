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

3. **Update Requirements:** Whenever the user asks for new requirements, update `docs/REQUIREMENTS.md` for future reference. When new domain concepts arise, update `CONTEXT.md`. Writing an ADR is not part of this loop — they are rare and never self-initiated (see below).
4. **Re-read specs every 30 minutes** or when uncertain. Requirements drift causes wasted work.

## Domain Vocabulary (`CONTEXT.md`)

`CONTEXT.md` holds the **core vocabulary of the domain** — the handful of words the project is thought in. Its job is to converge discussion and decisions, so that everyone means the same thing by the same word. It is not a dictionary of everything nameable, and it is not where mechanism is described.

- **Use CONTEXT.md vocabulary verbatim** in code, docs, commit messages, PR descriptions, UI copy.
- **Code and user-facing copy use the same terms.** Any divergence between code identifiers and UI labels needs a specific reason (cadence-flavour, established vernacular, accessibility) and an unambiguous mapping recorded in the relevant term's definition or Flagged ambiguities.

### What earns an entry

Core, not merely nameable. A term qualifies when:

1. **You cannot describe what the product does without the word.** If the product can be explained end to end without ever saying it, it is not core.
2. **The word is the user's, not the code's.** It appears in how the user talks, in the UI, and in the code. A word coined in the code — a class, a column, a subsystem — is not domain vocabulary; it needs no entry anywhere.
3. **The user deliberated it** — the [same bar as an ADR](#deliberation-bar). A term you minted by yourself, while doing something else, is a name you needed for one PR. Leave it in the code; propose the term instead.

Watch for terms nothing else in the glossary is defined in terms of — they are *candidates* for cutting, never automatic ones. A genuinely core term that arrived recently has nothing pointing at it yet, and pruning by that signal alone eventually fells the whole tree.

### Entry shape

**The term, what it means, and what we never call it.** The banished synonyms are half the value — "an Outcome, never a task or a todo" is what actually converges a conversation. A sentence or two; past roughly 80 words an entry has started describing mechanism rather than fixing a word.

- **New concepts the user thinks about** → add to the Conceptual tier first, then implement. The model can run ahead of the implementation; that is by design.
- **Code conflicts with the conceptual model** → log under that context's Flagged ambiguities. It is a punch list, so entries **leave** it: when the mismatch is resolved, delete the entry and fold the result into the term. Never annotate it as resolved and leave it in place.
- **No history, no status, no counts.** Not "the app now runs on X end to end", not "four kinds are A and fourteen are B". Rewrite the term; delete what stopped being true.

## Architecture Decision Records (`docs/adr/`)

ADRs preserve the reasoning behind decisions that future contributors would otherwise re-litigate blind. There are very few of them, and writing one is rare enough to be an event.

Most reasoning is disposable — re-derivable from the code by whoever next needs it, and what isn't is already in the PR description. An ADR is what survives both filters, which is close to nothing. Reasoning being hard-won is not the test: you thought hard because the work was hard, not because the conclusion is load-bearing.

- **Before architectural changes:** scan `docs/adr/` for prior decisions that might apply or constrain. An ADR represents a deliberate choice, not a default.
- <a id="deliberation-bar"></a>**Never write an ADR on your own initiative.** An ADR records a decision *the user deliberated and took*. A decision you reached alone was derivable, so the next reader can derive it too. When the decision was taken with the user, **ask before writing** — they are at the table already and the question costs a sentence. Absent a yes, there is no ADR.
- **A user-taken decision still has to meet all three criteria:**
  1. **Hard to reverse** — undoing it costs more than a code change: a migration, a data backfill, a wire-format bump, a renegotiation with a peer or with users. If a later change of mind is just a different edit to the same files, it is not an ADR.
  2. **Surprising without context** — a future reader would wonder "why on earth did they do it this way?"
  3. **The result of a real trade-off** — there were genuine alternatives, picked between for specific reasons.
- **Not an ADR, however much thought went in:** bug fixes (the rejected alternative was the broken behaviour), dependency/tooling/CI conventions, code organisation and naming, and anything whose rationale is a paragraph in the PR description.
- **Filename:** `docs/adr/NNNN-slug.md`, sequential numbering (scan the directory for the highest existing number and increment by one). Because authorship goes through the user, two branches should not be claiming a number at once; if it happens anyway, renumber the later one at merge and fix its inbound references.
- **Length:** 1–3 paragraphs, and a single paragraph is a fine ADR. Record *that* a decision was made and *why* — not how to implement it. If it wants section headings, a rejected-alternatives list, or more than a page, that material belongs in the PR description or a proposal doc; the ADR is the short thing that outlives them.
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

### Naming
- **Be explicit and descriptive.** A name should tell the reader what the value is, its units, and where it comes from — without chasing the definition. `duration_minutes` over `duration`; `retry_delay_ms` over `delay`; `unresolved_item_count` over `n`.
- **Encode units and dimensions in the name** (`_minutes`, `_ms`, `_bytes`, `_utc`). A unit mismatch hidden behind a bare name is a silent bug; one spelled out in the name is a visible diff.
- **New cached/denormalized values MUST carry `cache` in the name**: `cached_xyz` or `xyz_cache` (e.g. `total_minutes_cache`, `cachedAvatarUrl`). A cache can be stale by definition — the name warns every reader that the value is derived, and makes a write path that forgets to recompute it stand out in review. A derived value stored under an innocent name *will* eventually be read as if it were the source of truth. Existing persisted/API names that predate this rule keep their names until their migration or retirement.
- **Name the source of truth plainly, the derivation after its origin.** If a value is computed from an event log or another table, prefer deriving it at read time; when it must be stored, the name (per the rule above) is the contract that it is a copy, not the truth.
- Abbreviations only when they are more familiar than the expansion (`id`, `url`, `db`) — never to save keystrokes.

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

**Every document in `docs/` is a map.** A map exists to get you your bearings and send you somewhere; it is never a reproduction of the territory. You do not draw every leaf and every crack in the sidewalk. What changes between documents is scale, not kind:

- `README.md` — what the project is. Human developers start here.
- `docs/ARCHITECTURE.md` — the country map. 20,000 ft: the regions, and the roads between them.
- The design docs (`DESIGN.md`, `SYNC.md`, `TESTING.md`, `BACKEND_GUIDELINES.md`) — city maps. One region at a scale that shows its canals and watersheds. Still maps.
- The code — the streets. You walk them; nobody draws them twice.

### What a doc says, and what it defers

- **WHAT we are doing** → the doc. This is the only thing it holds outright.
- **WHY** → a *link* to the ADR, the NOTES entry, or the CONTEXT term. Never a restatement. If the reason is worth writing, it belongs in exactly one of those and the doc points at it.
- **HOW** → the codebase. Anything a reader could establish by opening the file is not written down. Class-by-class descriptions, flow walkthroughs and field inventories are territory, not map.
- **HOW IT CAME TO BE** → `git blame`, the PR, the issue. No document carries history, status or progress.

### Scale is enforced by size

A map that no longer fits in one sitting has stopped being a map, whatever it contains. That makes length the real constraint, not subject matter — so the ceilings are enforced in CI, and at the ceiling nothing is added without something being removed.

The numbers live in [`tools/check_doc_size.py`](tools/check_doc_size.py), which is their single source of truth; run `make docs-size` to see where every doc stands. A design doc is allowed slightly more than `ARCHITECTURE.md`: it covers less ground at higher fidelity and needs the room for it. Genuinely tabular reference data — device coordinates, matrices — is exempt, because a word count is the wrong instrument for a table.

Several docs were far above their ceiling when it was adopted, so enforcement is a **ratchet**: a doc over its ceiling may only shrink. Nothing gets worse from today, cleanup is never blocked, and the ceiling takes over the moment the doc drops under it.

### Maintenance

- Update the relevant document in the same change as the code — not at the end of the session. Treat docs as part of the code.
- Rewrite affected sections so they describe the new state. Never append "Updated X" or "Changed Y".
- Remove statements that stopped being true, and statements that were never worth making. Stale claims are worse than missing ones; so is a correct sentence nobody needed.
- If scope, goals or direction changed — not just implementation — update `REQUIREMENTS.md` or `DESIGN.md`.
- If you are unsure whether a doc needs updating, read it first and check.

## Keep Notes (`NOTES.md`)

NOTES.md records corrections to agent instincts: cases where the default, reasonable-looking approach was wrong in this project, and a fresh agent would likely make the same mistake even after reading the code and docs. It is not a changelog, not documentation, and not a work journal.

Before appending, apply two tests:

1. **Fresh-agent test.** Would a capable agent still get this wrong on a first attempt? If the fact is discoverable by reading the code or docs, it belongs there, not here.
2. **Routing test.** A fact about how the system works or is tested → docs/. What a change did and why → the PR description and commit message, which is where nearly all of it belongs. A decision the *user* took that is genuinely hard to reverse → offer them an ADR, never write one unprompted (see above). Only the wrong instinct itself goes here.

Write the entry as the correction, in one or two lines:

`- <date>: Instinct: X. Here: Y — <why>.`

If an entry can't be phrased that way, it belongs somewhere else. Codebase traps that keep biting (test-harness quirks, framework gotchas) go in the relevant doc — the doc update is mandatory, a NOTES pointer is optional. Don't ask permission; do apply the tests.


