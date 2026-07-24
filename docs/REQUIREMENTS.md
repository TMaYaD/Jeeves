# Product Requirements Document (PRD): GTD Execution Hybrid App

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

## 1. Product Vision
To build a hybrid productivity application that merges the rigid organizational trust of a Getting Things Done (GTD) inventory (e.g., Nirvana) with the focused, day-to-day execution layer of a daily planner and timeboxer (e.g., Sunsama). The system prioritizes immediate execution through Pomodoro constraints and maintains data integrity through forced behavioral guardrails.

## 2. Core Principles
* **Action over Organization:** The interface must drive the user toward execution, hiding the complexity of the larger GTD inventory during focus phases.
* **System Integrity is Paramount:** A productivity system fails when the data rots. The app will enforce necessary friction (guardrails) to ensure the user reviews and updates their inventory.
* **Local-First Performance:** Task capture and execution (timers/state changes) must work flawlessly offline to prevent user frustration.

---

## 3. Epics & Functional Requirements

### Epic 1: The GTD Inventory Engine
**Goal:** Establish a rock-solid backend for strict GTD methodology.
* **Universal Inbox:** A holding zone for all unprocessed captures.
* **Clarify Mode:** A synced, per-user preference (`clarify_mode`, Settings → Clarify) selecting how the clarify act maps Captures onto Outcomes. **1-1 mode** (the default) clarifies each Capture to at most one Outcome: routing to an Intent creates exactly one Outcome and stamps `clarified_at` automatically at that first Outcome link, while a discard is a valid zero-Outcome clarification that stamps the Capture without creating anything. **n-m mode** is split/merge: the user explicitly completes each Capture and only that completion stamps `clarified_at`, so a Capture stays in the Inbox while Outcomes are carved out of it. The mode is a preference over the same many-to-many storage, never a storage change — toggling mid-stream leaves every existing Capture and provenance link valid. The preference and its Settings toggle ship ahead of the n-m clarify surfaces, so selecting n-m persists and replicates but does not yet change clarify behaviour.
* **Data Schema:** Tasks must support the following metadata:
    * Project
    * Area of Responsibility (AoR)
    * Contexts (Tags)
    * Time Estimate
    * Energy Level
* **System Views:** Auto-generated lists for 'Next Actions' (clarified, non-done, `intent = 'next'` todos that either carry a current Action (`next_action_text IS NOT NULL AND TRIM(next_action_text) != ''`) or carry no `Tag(type='person')` — the single excluded quadrant is actionless-and-PersonBlocked, which surfaces only on Waiting For), 'Waiting For' (clarified, non-done, `intent = 'next'` todos carrying at least one `Tag(type='person')` via the `todo_tags` junction, grouped by Person), and 'Maybe' (todos with `intent = 'maybe'`). Next ∩ Waiting For overlaps by design when both predicates apply.
* **Record Surfaces (Done & Trash):** Two de-emphasised drawer entries (bottom of the scrollable nav column, above Settings, no count badges) open read-oriented list views: 'Done' (completed, non-trashed Outcomes, most recently completed first) and 'Trash' (Outcomes with `intent = 'trash'` regardless of Completion, newest-trashed first). Done and Trash are disjoint — a completed-then-trashed Outcome surfaces in Trash only. Neither view applies the context-tag filter. Rows open task detail, where a trashed Outcome can be restored to a chosen Intent (Next or Someday/Maybe) and a done Outcome restored to Next; restore clears `done_at` and stamps `last_clarified_at`. There is no purge / "empty trash" action — rows are never physically deleted.
* **Sequential Logic:** Dependency tracking between tasks is deferred to TMaYaD/Jeeves#181 (polymorphic blockers). The `blocked` state and `blocked_by_todo_id` field have been removed in alpha (migration 0012).
* **Context Tag Cloud:** A sticky, multi-select tag filter in the primary navigation drawer. Each chip shows the context name and its active-task count; chip weight (size/opacity) reflects relative count. Selecting one or more chips filters all list views to tasks carrying **all** selected tags (AND semantics). The filter persists across screen navigation until explicitly cleared. Long-pressing a chip opens tag management (rename, recolour, merge).
* **First-Launch Onboarding:** When the database is empty and the user has never interacted with the app, an onboarding card is shown in the inbox body. The card offers three affordances: Start fresh (dismiss and use the empty inbox), Import from Nirvana export (navigate to the import screen), and Sign in to sync (navigate to the login screen). Each action permanently dismisses the card (stored in SharedPreferences; never resets). The card also disappears automatically as soon as any item exists in the database — a Capture in the Inbox or an already-clarified Outcome, whichever a Nirvana import produced — so the user is never shown it after their first data arrives.

### Epic 2: The Daily Execution Layer
**Goal:** Prevent overwhelm by filtering the GTD inventory into a manageable daily plan.
* **Daily Planning Entry:** Ceremonies are never auto-launched — no route-level redirect may open one; every entry is an explicit user action (button, banner, or notification action). The canonical entry-point is the "Plan the Day" button on the execution home screen (route `/focus`, user-titled "Now" — see CONTEXT.md's term-unification divergence list). Users are additionally nudged through two opt-in mechanisms:
    * **Persistent banner:** A dismissible "Plan your day →" banner shown at the top of all main views until the ritual is completed or dismissed for the day. Configurable via Settings. The banner suppresses itself when the inbox and next-actions are both empty while waiting-for or someday/maybe still hold items, yielding the slot to the "Start Weekly Review" banner (see Epic 5). Precedence: when the weekly review is due, the "Start Weekly Review" banner takes the slot; otherwise the "Plan your day →" banner appears per its own conditions.
    * **Scheduled notification:** A local push notification at the user's configured planning time (default 08:00) with actions — Open, Snooze (configurable duration: 15 min / 1 hr / tomorrow), and Skip today. Skip suppresses all nudges until the next calendar day. Snooze reschedules a one-off notification. All state persists across app restarts.
    * Settings: planning time, default snooze duration, enable/disable notification, enable/disable banner.
* **Daily Planning Ritual:** A guided 5-step wizard followed by a completion screen:
    1. **Clarify Inbox (Step 1):** Process a stable snapshot of the inbox one item at a time. For each item, the user answers "What's the expected outcome?", sets fields (energy level, time estimate, due date), and routes it by Intent (Next, Waiting For, Maybe, or Done) — or skips it, leaving it in the inbox. A due date is an attribute set alongside the routing, not a destination — there is no "Scheduled" list or state. Next step crosses into Step 2 once the cursor has walked the whole snapshot.
    2. **Review Tasks (Step 2):** The re-clarification surface. Tasks needing review — stale (worked on in a session more recently than last clarified) or actionless (no next-action phrase) — surface one at a time with a context-aware action menu ("Still relevant" / "Still waiting" / update the next action / route elsewhere). When nothing needs review, the step renders an empty-state view and the user clicks Next to advance — steps never auto-skip (CONTEXT.md § Wizard).
    3. **Energy Check-in (Step 3):** User reports today's energy level (Low / Medium / High).
    4. **Time Check-in (Step 4):** User reports today's available time (hours + minutes).
    5. **Review Next Actions (Step 5):** Select tasks for today from the Pending Review list — individually or via long-press multi-select. In multi-select mode a contextual bar above the list shows the selected count, the previewed planned time, "Select all" / "Clear" actions, and a primary "Add to Today" button that commits the batch. The step also shows the running Today's Plan list and a capacity bar that warns if planned time exceeds available time. Selected Outcomes that carry no time estimate are counted at a configurable default (10 minutes by default, changeable in Settings); these default-counted minutes show as a lighter-blue segment of the capacity bar and are never persisted onto the Outcome.
    * **Today's Schedule (completion screen):** Rendered outside the wizard once the last step is walked — a post-ceremony confirmation, not a step. Shows the day's tasks (due-dated first, ascending, then the rest) and a calendar placeholder. "Start Day" finalises the plan, opens the FocusSession, and lands on the execution home.
* **Ceremony back navigation:** System back inside any ceremony (Daily Planning, Evening Shutdown, Weekly Review) mirrors the footer Back affordance — it retreats the per-item cursor first, then the step. When footer Back is unavailable (first step, first item — or a completion screen), system back exits the ceremony to the execution home ("Now"), never to the launcher, and abandons the performance. An abandoned performance's working state persists as an in-memory draft that seeds the next performance — re-entry resumes at the same step and item; the draft silently degrades to a fresh start after process death (accepted behaviour). Post-completion "Re-plan" still resets the ritual state before re-entering.
* **Daily Planner with Calendar Integration (TMaYaD/Jeeves#40):** Read-only external calendar (Google/Apple) rendered alongside the day's Plan. Dragging a Plan entry onto the timeline creates a **Timebox** — a scheduled start + duration on the FocusSession Plan entry, session-scoped and dying with the session (ADR-0013). When a calendar is connected, the Day Check-in derives available time from calendar whitespace instead of asking. The timeline and the calendar read ship together — without external events the Day Check-in question already delivers the capacity value. Timebox write-back to external calendars is rejected on GTD principle (ADR-0014); the sole legitimate write case — hard-landscape commitments — is TMaYaD/Jeeves#410.
* **Capacity Warning:** Visual indicators (e.g., progress bars or red text) if the total estimated time of selected tasks exceeds the available free time (calendar whitespace when connected, the Day Check-in answer otherwise).
* **Focus Mode:** A minimalist execution UI showing only the active task. Activated via a "Start" button on any task in the daily plan, or via the "Start focus" affordance on the task detail screen (`/task/:id`) — which engages the task with or without an open FocusSession: with a session, the TimeLog attributes to it and the Focus pointer may reference an off-Plan task; without one, the TimeLog is ad hoc with no session attribution (ADR-0005). Displays the task title, a Jeeves-flavoured elapsed-time banner, and a sprint ring with a countdown timer. The sprint ring contains an in-ring phase-skip control: "Start break" (coffee icon) during a sprint, "Start sprint" (play icon) during a break. The bottom action bar has two controls: Stop (red outlined, returns to focus list without completing) and Done (filled blue, marks task complete and returns to focus list). A swipe-left carousel page shows task notes (editable inline). A persistent notification appears when the app is backgrounded. Session-backed focus tracks the active task in `focus_sessions.current_task_id`; ad-hoc focus (no open FocusSession) is durably tracked by its open TimeLog. Sprint timer phase, end-time, sprint/break counters, and overtime start are persisted to SharedPreferences by `SprintTimerProvider` and restored on provider startup, so timer state survives app restarts.
* **Session Review (Wrap-Up):** When the user taps "End Session" on the Focus screen, any unfinished tasks trigger the session review screen. For each pending task the user chooses one of three dispositions:
    * **Roll Over** — pre-select the task for the next planning session (task keeps `intent = 'next'`; shown pre-checked in the next plan summary).
    * **Leave** — return the task to Next Actions without any change.
    * **Maybe** — defer the task; `intent` is set to `'maybe'` so it moves to the Someday/Maybe list.
    Done tasks are shown in a read-only section with no chips. The "Close Session" button is disabled until all pending tasks have been assigned a disposition. If all tasks are already done, the session closes immediately without showing the review screen. Dispositions are recorded on `focus_session_tasks.disposition` (Alembic 0021, Drift migration 16) as a historical record; `NULL` means not yet reviewed.

### Epic 3: Dynamic Timeboxing & Pomodoro Engine
**Goal:** Adapt rigid time constraints to varying task lengths.
* **Core Intervals:** System defaults to 20-minute focus sprints and 3-minute breaks.
* **Automated Chunking:** If a task with a 60-minute estimate is dragged to the calendar, the system automatically visually subdivides it into three 20-minute sprint blocks with break gaps.
* **Algorithmic Batching:** Suggestion engine to group multiple micro-tasks (e.g., three 5-minute tasks with the same Context) into a single 20-minute sprint block.

### Epic 4: Sprint Resolution Protocol
**Goal:** Handle incomplete work gracefully at the end of a sprint without breaking the daily calendar.
* **End-of-Sprint Interstitial:** Mandatory UI prompt when a 20-minute timer expires, blocking the break until a resolution is chosen.
* **Resolution Matrix:**
    * **Complete:** Log 20 mins, mark task Done.
    * **Extend (Bump & Continue):** Allocate another 20-minute block to the current task. The system automatically prompts the user to "punt" the lowest-priority remaining task from the day's plan to prevent calendar overrun.
    * **Defer (Log & Park):** Log 20 mins, remove from today's plan, and return it to 'Next Actions'.
* **Estimation Analytics:** System tracks the delta between estimated and actual pomodoros to improve future AI estimations.

### Epic 5: System Integrity & The Review Guardrails
**Goal:** Prevent inventory rot through behavioral nudges and progressive friction.
* **Weekly Review Wizard:** A 5-screen ceremony surfaced when the user has not completed a review in seven days. The wizard runs through four GTD review steps (Process Inbox → Review Waiting For → Review Next Actions → Review Someday/Maybe) and a Summary screen. There is no separate brain-dump/capture step — capture happens via the inbox throughout the week (share-sheet, voice, manual entry), so the review only clarifies what was already captured. The cadence is fixed at 7 days.
    * **Entry points:** A "Start Weekly Review" banner above the main views when the review is due, **or** when the inbox and next-actions are both empty while waiting-for or someday/maybe still hold items (in which state the daily planning banner suppresses itself, so the weekly-review banner takes its place). Plus a daily local notification at the user's configured time (default 09:00) with actions Open / Snooze / Skip today.
    * **Behaviour:** Each list-driven step iterates through items one at a time using a stable snapshot. All step snapshots are pre-loaded when the ceremony starts, so the order doesn't shift while the user is working and items routed in an earlier step (e.g. inbox → maybe) cannot leak into a later step's list. While the cursor is on a real item the footer shows Skip, which advances the cursor (Back symmetrically retreats it); once the cursor has passed the last item, Next step takes Skip's place and crosses into the following step. Inbox clarification uses the same card UI as the daily-planning ritual. Each per-item step (Waiting For, Next Actions, Someday/Maybe) also offers a `Re-clarify…` action that opens the full clarification UI as a sub-flow over the current item; routing inside the sub-flow advances the cursor, while backing out without routing keeps the item and advances. A list-driven step whose snapshot loads empty renders an inline empty-state view; the user clicks Next to advance (steps do not auto-skip, per CONTEXT.md § Wizard). Tapping Done finalises the completion timestamp (synced across devices) and returns the user to the inbox.
    * **Persistence:** Last completion date, banner-dismissed date, and notification/banner settings are stored as user preferences and replicate across devices.
* **System Trust Score:** Background monitoring of inventory health (unprocessed inbox items, stale tasks, overdue reviews). *(Deferred — Trust Score and Progressive Restriction levels are tracked in TMaYaD/Jeeves#52.)*
* **Stale Task Sweeper:** Forces a binary choice (Move to Maybe OR Delete) on tasks bypassed/rescheduled more than three times. *(Deferred to TMaYaD/Jeeves#107 — extends the existing `_needsReviewWhere` predicate with a skip-count axis and prefixes Step 4 of the Weekly Review with a forced-resolution surface.)*

### Epic 6: Contextual & Geofenced Surfacing
**Goal:** Reduce cognitive load by hiding irrelevant tasks based on time and physical location.
* **Time-Bound Surfacing:** Contexts tied to hours (e.g., 'Work' tasks auto-hide at 17:00).
* **Geofenced Contexts:** Map physical locations to Contexts. App surfaces specific tasks when entering the GPS geofence.
* **Errand Handoff:** Group location-tagged tasks. Provide a single export button to pass coordinates via URL scheme to native navigation apps (Google Maps/Waze) for route optimization. *(Note: Do not build native route planning.)*

### Epic 7: Android OS Deep Integration
**Goal:** Zero-friction capture in mobile environments.
* **Native Share Sheet:** Register app as a target to parse text, URLs, and attachments directly to the Inbox.
* **Voice Assistant Intents:** `actions.intent.CREATE_THING_TO_DO` integration for hands-free capture via Google Assistant.

### Epic 8: AI-Assisted Triage (The Clarify Step)
**Goal:** Reduce the friction of organizing the Inbox.
* **Auto-Triage:** LLM parses raw inbox text and suggests Project, Context, Energy, and Duration.
* **Human-in-the-Loop:** User must explicitly approve/modify AI suggestions before committing to the inventory.
* **Conversational Capture:** Audio interface for brain-dumping, where the system prompts the user verbally to define GTD parameters.
* **Interactive Verbal Clarifier:** Structured verbal Q&A that prompts the user through GTD clarification questions for a single task, distinct from the passive conversational brain dump.
* **AI-Powered Tag Summary:** On-demand AI-generated summary of all tasks under a given tag — task count, completion status, overdue highlights, and next actions.
* **Graceful AI Degradation:** All AI-powered features must fall back gracefully when the AI service is unavailable, ensuring core GTD workflows remain fully functional without intelligence features.

### Epic 9: Habit Tracking
**Goal:** Support recurring behavioral commitments that don't fit the "complete and forget" model of a GTD task.
* **Habit Definition:** Create habits with title, frequency (daily, specific weekdays, X times per week/month), time-of-day anchor, and optional context/location link.
* **Check-In:** Binary (done/not done) or measurable (numeric value, e.g., "glasses of water: 6").
* **Streak Tracking:** Current streak, best streak, completion rate over 7/30/90 days. Flexible frequency awareness — rest days don't break non-daily streaks.
* **Visualization:** Heatmap/calendar view showing consistency over time.
* **GTD Integration:** Habits surface in the Daily Planning summary (without consuming task capacity), morning review, Evening Shutdown check-in, and context/location-based surfacing. Habits can optionally be worked on in Focus Mode with Pomodoro timing.

### Epic 10: Extended Capture Channels
**Goal:** Meet users where they are with additional low-friction capture methods beyond the core app and Android OS integration.
* **Home Screen Widget:** Quick-capture widget for task entry without opening the app.
* **Email-to-Inbox:** Forward emails to a dedicated address to create inbox items.
* **Messaging Integration:** Capture tasks via messaging platforms (e.g., Telegram bot, WhatsApp).
* **Scheduled Reminder Notifications:** Timezone-aware local push notifications for tasks with due dates, ensuring users are reminded of deadlines even when the app is closed.

### Epic 11: Data Portability & Migration
**Goal:** Reduce switching costs and prevent vendor lock-in.
* **Import from Nirvana:** One-time migration of tasks, projects, contexts, and metadata from Nirvana GTD export (CSV or JSON), preserving GTD state and hierarchy. The parser classifies each source state (`app/lib/import/nirvana_parser.dart` implements the table; `app/test/import/nirvana_parser_test.dart` pins it); the local importer then routes an unclarified item to a **Capture** and a clarified one to an **Outcome** (`app/lib/import/nirvana_local_import.dart`). Clarified rows are bucketed by three fields — `intent`, `doneAt`, and person tags:

| Nirvana state | Import outcome |
| :--- | :--- |
| Inbox — and any unrecognised state (e.g. CSV `active`, JSON 11 for active projects) | Becomes a **Capture** in the Inbox (`clarified_at IS NULL`); its Nirvana tags (project / context / `WAITINGFOR` person) become Capture **tag hints** (`capture_tags`). Recognised states form a positive whitelist so unknowns can't slip silently into active lists. |
| Next, Waiting | Becomes an Outcome (`intent='next'`). A non-empty `WAITINGFOR` value becomes a person tag on the imported Outcome. |
| Someday, Inactive-Later | `clarified=true`, `intent='maybe'`. |
| Scheduled, Scheduled-Repeating, Reference | `clarified=true`, `intent='maybe'`, plus an `@scheduled` / `@repeating` / `@reference` context tag — Jeeves has no Scheduled/Repeating/Reference primitive, so the original category stays recoverable after import. |
| Trash | `clarified=true`, `intent='trash'`. |
| Completed — Logbook, non-empty `COMPLETED` (CSV), or non-zero `completed` (JSON), regardless of state | `doneAt` set (the completion date, or import time when unparseable), `intent='next'`. Completed wins: no `@scheduled`/`@repeating`/`@reference` auto-tag is injected. |

  JSON exports carry state ints rather than literals: the recognised (clarified) set is `{1–7, 9, 10}`, of which `{3, 4, 5, 9, 10}` map to Maybe and `{6}` to Trash, with auto-tags 3 → `@scheduled`, 9 → `@repeating`, 10 → `@reference`; 0 and unrecognised ints fall to the Inbox row above.

---

## 4. Prioritization Roadmap

| Phase | Focus | Target Epics | Rationale |
| :--- | :--- | :--- | :--- |
| **Phase 1: Core Engine** | Data Model, Basic CRUD, Daily Planner (read-only calendar) | Epic 1, Epic 2 | Highest technical risk and foundational necessity. The app fails without a stable local-first database; the planner's calendar read completes the day loop's value (TMaYaD/Jeeves#40). |
| **Phase 2: Execution Loop** | Pomodoros, Resolution Matrix, Guardrails | Epic 3, Epic 4, Epic 5 | The core differentiator (80/20 value). Guardrails must be deployed before beta testing to prevent garbage data accumulation. |
| **Phase 3: OS Hooks** | Share Sheet, Geofencing, Time Filters | Epic 6, Epic 7 | High value, moderate effort. Improves capture flow and contextual filtering. |
| **Phase 4: Intelligence** | AI Triage, Conversational Capture | Epic 8 | Highest latency/cost risk. Treat as a progressive enhancement built on top of the solid manual workflows. |
| **Phase 5: Behavioral Layer** | Habits, Extended Capture | Epic 9, Epic 10 | Expands the system from task management into holistic productivity. Habits address the recurring-task workaround users already employ. |
| **Phase 6: Portability** | Import/Export, Migration | Epic 11 | Reduces onboarding friction for users switching from other GTD tools. |

---

## 5. Architectural Directives

* **Engineering:** Prioritize Local-First data storage to eliminate UI latency. Manage Intent and Completion transitions, due-date edits, and focus tracking (`focus_sessions.current_task_id`) rigidly to ensure accurate time logging.
* **Design:** Maintain a strict visual dichotomy. High information density for the GTD Inventory (planning phase) and extreme minimalism for Focus Mode (execution phase). Ensure Guardrail interruptions are clear, explaining the *why* behind the restriction.
* **Optional Authentication:** The app must be fully functional without login. Authentication is only required for cross-device sync via PowerSync. Users can operate indefinitely in local-only mode, with opt-in sign-up to enable sync. Local data must be preserved and migrated on first sign-in.
* **Sync:** Real-time bidirectional sync between local SQLite (Drift) and PostgreSQL via self-hosted PowerSync. The sync layer activates only after authentication and must handle offline write queuing and conflict resolution (last-write-wins for v1).
* **Cross-Device Settings Sync:**
    * **Storage:** User preferences (sprint/break durations, planning time, notification and banner toggles, snooze duration, clarify mode) and ceremony state (banner dismissed, notification skip/snooze, Evening Shutdown check-in completed — see Epic 2) are stored in the `user_preferences` table and replicated across devices via PowerSync. Sprint timer ephemeral state (current phase, end-time, sprint/break counters) remains in `SharedPreferences` only and is not synced.
    * **Source of truth:** `syncedPreferencesProvider` is the single source of truth for synced preferences; providers that derive state from preferences watch it via `ref.listen` and re-derive state automatically when remote changes arrive via PowerSync.
    * **Migration:** On the first app launch after upgrade, a one-time migration copies the following known keys from `SharedPreferences` into the Drift `user_preferences` table: settings keys (`focus_settings_sprint_duration_minutes`, `focus_settings_break_duration_minutes`, `focus_session_planning_settings_time_hour`, `focus_session_planning_settings_time_minute`, `focus_session_planning_settings_notification_enabled`, `focus_session_planning_settings_banner_enabled`, `focus_session_planning_settings_default_snooze_duration`) are moved and cleared from `SharedPreferences`; ceremony keys (`planning_banner_dismissed_date`, `planning_notification_skipped_date`, `planning_notification_snoozed_until`, `shutdown_ritual_completed_date`, `shutdown_banner_dismissed_date`, `shutdown_notification_skipped_date`, `shutdown_notification_snoozed_until`) are copied but retained in `SharedPreferences` for cold-start reads. Keys introduced after that migration — `clarify_mode` — have no `SharedPreferences` ancestor and are not part of it: the row is absent until the user first changes the setting, and an absent row reads as the key's documented default (`oneToOne`).
