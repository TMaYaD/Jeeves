# Agent Instructions

Generic instructions for AI agents. Copy-pasteable to any project.

## First Steps

1. **Check the scratchpad** (`SCRATCHPAD.md`) for current goal
2. **Read project documentation:**
   - `README.md` - Project overview
   - `docs/REQUIREMENTS.md` - What we're building
   - `docs/ARCHITECTURE.md` - How it's built
   - `docs/TESTING.md` - Testing strategy
   - `docs/DESIGN.md` - Design system

3. **Update Requirements:** Whenever the user asks for new requirements, update `docs/REQUIREMENTS.md` for future reference.
4. **Re-read specs every 30 minutes** or when uncertain. Requirements drift causes wasted work.

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

## Versioning Policy (CRITICAL)

Strictly follow Semantic Versioning.

## Workflow

1. **Understand** - Read docs, understand the task
2. **Test** - Write failing test defining expected behavior
3. **Implement** - Make test pass
4. **Refactor** - Clean up, tests still pass
5. **Verify** - Full test suite, build check
6. **Update scratchpad** - Mark goal done, set next goal

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
| `README.md` | Project overview | Project-specific |
| `docs/` | Detailed documentation | Project-specific |

Keep AGENTS.md generic. Project details go in README.md and docs/.

## Documentation in docs/

Files in docs/ (ARCHITECTURE.md, BACKEND_GUIDELINES.md, DESIGN.md, REQUIREMENTS.md, TESTING.md) describe the current state of the project. They are not changelogs. A reader should be able to understand the system today by reading them, without consulting git history, issues, or PRs.
When you change code that affects anything these documents describe, update the relevant document in the same change — not at the end of the session. Treat the docs as part of the code.
When updating:

Rewrite affected sections so they describe the new state. Do not add "Updated X" or "Changed Y" notes.
Remove statements that are no longer true. Stale claims are worse than missing ones.
If scope, goals, or direction changed (not just implementation), update REQUIREMENTS.md or DESIGN.md accordingly.
If you're unsure whether a doc needs updating, read the doc first and check. Don't skip this step.

Git history and GitHub issues are the source of truth for how and why the system got here. The source code is the source of truth for what it is now. /docs is a summary of both.

## Keep Notes

When you make a non-obvious decision, encounter a surprise about this codebase, or learn something by failing an approach first, append a one-line entry to NOTES.md under today's date before moving on. Don't ask permission.


