# User Testing Goals

Realistic goals a first-time user would attempt. Each goal is exercised by a separate exploration subagent.

## Capture & Inbox
1. Capture five quick tasks into the inbox (cold-start brain dump).
2. Clarify and organize the inbox to zero — outcome, energy/time/context, route to Next / Maybe / Waiting.
3. Convert an inbox item into a project (parent + sub-actions) rather than a single action.

## Planning & Daily Ritual
4. Plan today using the Daily Planning ritual (energy check-in → review → estimates → summary).
5. Multi-select several Next Actions during planning review and pull them into today in one gesture.
6. Re-clarify a stale task (aged `last_clarified_at`) via the Daily Planning review step.
7. Change planning time so "today" rolls over at a different hour.

## Execution & Wrap-up
8. Run a focus session on a planned task; pause, resume, complete.
9. End the day with Session Review — triage incomplete tasks as Roll Over / Leave / Maybe.
10. Demote a task mid-day and resolve it at Evening Shutdown.
11. Roll over an unfinished task and confirm it appears in tomorrow's plan.

## Inventory Navigation
12. Find and review the Waiting For list (incl. tasks marked "Waiting on <person>").
13. Move a task to Someday/Maybe and later resurrect it to Next Actions.
14. Filter tasks by context tag using the tag cloud.
15. Attach a person tag (`@alice`) and find every task involving that person.
16. Rename/recolor a tag from the long-press management sheet.
17. Universal search across title, notes, project, tags.

## Resilience & Lifecycle
18. Use the app fully offline (airplane mode) and confirm captures persist across restart.
19. Skip account creation, use as local-only, then sign in later from Settings to enable sync.
20. Import an existing GTD inventory from a Nirvana export on first launch.

---

## Flagged as likely out-of-scope for current build
Confirm before including in exploration:

- Calendar-sync capacity warnings comparing planned duration to free time on an external calendar.
- Full Sprint/Pomodoro spillover matrix (Complete / Extend / Defer at sprint expiry).
- Trust Score / Progressive Friction lockouts of Daily Planning.
- Algorithmic chunking of large tasks into 20-min sub-blocks.
- Web build / Solana Seeker SIWS auth surfaces.
