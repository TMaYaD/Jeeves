# Rebase notes — `feat/evening-shutdown-83` onto post-#185 main

This note records the Phase 5 hunk walk for the evening-shutdown port (issue
#83). The donor branch was archived as `wip/evening-shutdown-83-archive`; the
working branch was reset to `origin/main` and the shutdown feature re-laid on
top in two commits:

- `a0e7f2d` — feat(shutdown): port evening shutdown ritual onto FocusSession internals
- `86e6c63` — test(shutdown): cover EveningShutdownNotifier and stream providers

The diff `wip/evening-shutdown-83-archive..feat/evening-shutdown-83` is large
(~16k lines) because the donor was forked from old main and almost all of the
non-shutdown delta is the wider task-model / FocusSession refactor (PR #185
and friends) that landed on main between the donor's fork point and the rebase
target. Every hunk falls into one of three buckets:

1. **Donor → main (kept verbatim)** — shutdown UI/domain code that was
   bucket-A wholesale or bucket-B hand-ported with semantics intact.
2. **Donor — rewired against new internals** — code where the donor's
   intent was preserved but the data path was switched from FSM-era
   `state` / `selectedForToday` / `TodoDao` bypasses to the post-#185
   `FocusSessionDao` primitives + orthogonal task axes
   (`intent` / `clarified` / `done_at`).
3. **Donor — intentionally not carried over** — donor-side code whose only
   reason to exist was the FSM model that #185 deleted. Documented below.

## Intentionally not carried over

### `app/lib/database/daos/todo_dao.dart` — five donor-added methods (162 LOC)

| Donor method                     | Why dropped                                                                                                                                                                                                                |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rolloverTask(id, userId, date)` | Wrote `selectedForToday` + a per-task `selectedForDate`. Replaced by `FocusSessionDao.reviewAndCloseSession`, which records `disposition = 'rollover'` on the closing session; `getLastClosedSessionRolloverTaskIds` then seeds tomorrow. |
| `returnToNextActions(id, userId)` | Cleared `selectedForToday` and forced `state = 'unreviewed'`. Replaced by the in-memory `'leave'` disposition: a `next` / `clarified` / not-`done_at` task already surfaces in tomorrow's planning without any mutation. |
| `deferTaskAtShutdown(id, userId)` | Set `state = 'somedayMaybe'` and cleared `selectedForToday`. Replaced by the `'maybe'` disposition path inside `reviewAndCloseSession`, which atomically flips `intent = 'maybe'`. |
| `watchCompletedToday(userId, date)` | Filtered todos by `state = 'done'` AND `selectedForToday = 1` AND a per-task `selectedForDate`. Replaced by `watchSessionTasksForUser(userId).map(.where(t.doneAt != null))` directly inside `completedTodayProvider`. |
| `watchUnfinishedSelectedToday(userId, date)` | Same shape but inverted (`state != 'done'`). Replaced by `watchSessionTasksForUser(...).where(t.doneAt == null && !dispositions.containsKey(t.id))` inside `unfinishedSelectedTodayProvider`, where `dispositions` is the in-memory map on `EveningShutdownNotifier` (no intermediate DB writes). |

These would have been net-new additions on `TodoDao` had we ported them; the
post-#185 model has no equivalent columns to hang them on, and `FocusSessionDao`
already provides the join-through-the-active-session reads + the atomic close
semantics. Keeping the donor methods would have required also keeping the
columns #185 dropped, which is a non-starter.

### `app/test/database/shutdown_dao_test.dart` — 305 LOC, 14 tests

Every test exercised one of the five `TodoDao` methods above. Coverage of
the equivalent post-#185 primitives already lives in
`app/test/database/focus_session_planning_dao_test.dart` (28 tests across
`setTaskDisposition`, `reviewAndCloseSession`, `getLastClosedSessionRolloverTaskIds`,
`watchSessionTasksForUser`). The provider-level behaviour the donor cared
about — disposition recording, rollover seeding for tomorrow, the
`'maybe'` intent flip on close, the `'leave'` no-op — is covered end-to-end
in the new `app/test/providers/evening_shutdown_provider_test.dart`.

### `app/lib/screens/review/focus_session_review_screen.dart` (394 LOC) and `app/lib/providers/focus_session_review_provider.dart` (128 LOC)

Single-page session review shipped on main via PR-K (#198). Replaced wholesale
by the donor's 3-step ritual (`shutdown_ritual_screen.dart` +
`completed_review_step.dart` / `unfinished_tasks_step.dart` /
`shutdown_summary_step.dart`) per the rebase plan. The corresponding
`app/test/screens/focus_session_review_screen_test.dart` (219 LOC) was deleted
along with them.

### `app/lib/providers/evening_shutdown_provider.dart` — donor's `_today` / `_tomorrow` helpers and `shutdownSessionDateProvider` reads

Donor computed tomorrow's calendar date locally to stamp `selectedForDate`. The
new path threads task identity through `focus_session_tasks.disposition` instead,
so no calendar arithmetic is needed at the provider layer.
`shutdownSessionDateProvider` itself is preserved for any future UI that wants
to display the session date but no longer participates in the closeDay path.

### Donor's `_StartButton(label, todoId, inProgressSince)` API on `focus_screen.dart`

The donor passed a label string and an optional `inProgressSince` DateTime to
distinguish Resume from Start; resume relied on `Todo.inProgressSince` (a
column #185 dropped). Replaced with `_StartButton(todoId, isResume)` where
`isResume` is computed at the call site from `focus_session.current_task_id`,
and the resume path re-attaches to the open `time_logs` row instead of the
`todos.in_progress_since` column.

## Notes on bucket 1 + bucket 2

- All three donor step files (completed/unfinished/summary) and the screen shell
  were bucket-A: imported `evening_shutdown_provider.dart` symbols (`Todo`,
  `eveningShutdownProvider`, `completedTodayProvider`,
  `unfinishedSelectedTodayProvider`) which the rewired provider re-exports
  unchanged. Zero edits inside the step files.
- `shutdown_banner.dart`, `shutdown_settings.dart`, `shutdown_settings_provider.dart`,
  `shutdown_settings.dart` (model) — bucket A; only patched two import lines on
  the banner to reach `focus_session_planning_provider`/
  `focusSessionPlanningCompletionNotifier` (donor referenced the dropped
  `daily_planning_provider`).
- `notification_service.dart` shutdown methods were bucket B: identical to the
  donor's, with notification IDs reassigned from the donor's `2`/`3` to `4`/`5`
  to avoid colliding with main's `_kSprintEndNotificationId` /
  `_kBreakEndNotificationId` introduced by the sprint-timer feature.
- `main.dart` — bucket B hand-port: shutdown init/load calls and the three
  `kShutdownNotificationAction*` switch cases preserved verbatim; planning-side
  identifiers updated to the post-#185 `focus_session_planning_*` names.
- `app_shell.dart`, `router.dart`, `settings_screen.dart` — bucket B; only the
  shutdown-relevant adds (banner widget, `/shutdown` route, EVENING SHUTDOWN
  settings section) were carried; main's pre-existing structure was preserved.
