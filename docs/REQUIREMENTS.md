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
* **Data Schema:** Tasks must support the following metadata:
    * Project
    * Area of Responsibility (AoR)
    * Contexts (Tags)
    * Time Estimate
    * Energy Level
* **System Views:** Auto-generated lists for 'Next Actions' (clarified, non-done, `intent = 'next'` todos that either carry a current Action (`next_action_text IS NOT NULL AND TRIM(next_action_text) != ''`) or carry no `Tag(type='person')` — the single excluded quadrant is actionless-and-PersonBlocked, which surfaces only on Waiting For), 'Waiting For' (clarified, non-done, `intent = 'next'` todos carrying at least one `Tag(type='person')` via the `todo_tags` junction, grouped by Person), and 'Maybe' (todos with `intent = 'maybe'`). Next ∩ Waiting For overlaps by design when both predicates apply.
* **Sequential Logic:** Dependency tracking between tasks is deferred to TMaYaD/Jeeves#181 (polymorphic blockers). The `blocked` state and `blocked_by_todo_id` field have been removed in alpha (migration 0012).
* **Context Tag Cloud:** A sticky, multi-select tag filter in the primary navigation drawer. Each chip shows the context name and its active-task count; chip weight (size/opacity) reflects relative count. Selecting one or more chips filters all list views to tasks carrying **all** selected tags (AND semantics). The filter persists across screen navigation until explicitly cleared. Long-pressing a chip opens tag management (rename, recolour, merge).
* **First-Launch Onboarding:** When the database is empty and the user has never interacted with the app, an onboarding card is shown in the inbox body. The card offers three affordances: Start fresh (dismiss and use the empty inbox), Import from Nirvana export (navigate to the import screen), and Sign in to sync (navigate to the login screen). Each action permanently dismisses the card (stored in SharedPreferences; never resets). The card also disappears automatically as soon as any todo exists in the database — including clarified items from a Nirvana import — so the user is never shown it after their first data arrives.

### Epic 2: The Daily Execution Layer
**Goal:** Prevent overwhelm by filtering the GTD inventory into a manageable daily plan.
* **Daily Planning Entry:** The ritual is never auto-launched on app open. Users are nudged through two opt-in mechanisms:
    * **Persistent banner:** A dismissible "Plan your day →" banner shown at the top of all main views until the ritual is completed or dismissed for the day. Configurable via Settings. The banner suppresses itself when the inbox and next-actions are both empty while waiting-for or someday/maybe still hold items, yielding the slot to the "Start Weekly Review" banner (see Epic 5). Precedence: when the weekly review is due, the "Start Weekly Review" banner takes the slot; otherwise the "Plan your day →" banner appears per its own conditions.
    * **Scheduled notification:** A local push notification at the user's configured planning time (default 08:00) with actions — Open, Snooze (configurable duration: 15 min / 1 hr / tomorrow), and Skip today. Skip suppresses all nudges until the next calendar day. Snooze reschedules a one-off notification. All state persists across app restarts.
    * Settings: planning time, default snooze duration, enable/disable notification, enable/disable banner.
* **Daily Planning Ritual:** A guided 6-step workflow:
    1. **Clarify Inbox (Step 1):** Process every inbox item before queueing work. For each item, the user answers "What's the expected outcome?", sets fields (energy level, time estimate, due date), and routes it by Intent (Next, Waiting For, Maybe, or Done). A due date is an attribute set alongside the routing, not a destination — there is no "Scheduled" list or state. Advancing is gated on an empty inbox.
    2. **Day Check-in (Step 2):** User reports today's energy level (Low / Medium / High) and available time (hours + minutes).
    3. **Review Next Actions (Step 3):** Review unreviewed next-action tasks — select for today (individually or via long-press multi-select), skip, or defer to Maybe. In multi-select mode a contextual bar above the list shows the selected count, the previewed planned time, "Select all" / "Clear" actions, and a primary "Add to Today" button that commits the batch.
    4. **Today's Schedule (Step 4):** Confirm or reschedule tasks that are due today.
    5. **Time Estimates (Step 5):** Set time estimates on any selected task that is still missing one.
    6. **Today's Plan (Step 6):** Summary showing tasks sorted by priority — due date (ascending) → scheduled → next actions. Capacity bar warns if planned time exceeds available time. "Start Day" finalises the plan.
* **Daily Planner with Calendar Integration (TMaYaD/Jeeves#40):** Read-only external calendar (Google/Apple) rendered alongside the day's Plan. Dragging a Plan entry onto the timeline creates a **Timebox** — a scheduled start + duration on the FocusSession Plan entry, session-scoped and dying with the session (ADR-0013). When a calendar is connected, the Day Check-in derives available time from calendar whitespace instead of asking. The timeline and the calendar read ship together — without external events the Day Check-in question already delivers the capacity value. Timebox write-back to external calendars is rejected on GTD principle (ADR-0014); the sole legitimate write case — hard-landscape commitments — is TMaYaD/Jeeves#410.
* **Capacity Warning:** Visual indicators (e.g., progress bars or red text) if the total estimated time of selected tasks exceeds the available free time (calendar whitespace when connected, the Day Check-in answer otherwise).
* **Focus Mode:** A minimalist execution UI showing only the active task. Activated via a "Start" button on any task in the daily plan. Displays the task title, a Jeeves-flavoured elapsed-time banner, and a sprint ring with a countdown timer. The sprint ring contains an in-ring phase-skip control: "Start break" (coffee icon) during a sprint, "Start sprint" (play icon) during a break. The bottom action bar has two controls: Stop (red outlined, returns to focus list without completing) and Done (filled blue, marks task complete and returns to focus list). A swipe-left carousel page shows task notes (editable inline). A persistent notification appears when the app is backgrounded. The active task is tracked by `focus_sessions.current_task_id`; sprint timer phase, end-time, sprint/break counters, and overtime start are persisted to SharedPreferences by `SprintTimerProvider` and restored on provider startup, so timer state survives app restarts.
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
    * **Behaviour:** Each list-driven step iterates through items one at a time using a stable snapshot loaded when the step opens, so the order doesn't shift while the user is working. The footer Next button advances the per-step item cursor first (Back symmetrically retreats it); only when the user is on the last item does Next cross into the following step. Inbox clarification uses the same card UI as the daily-planning ritual. Each per-item step (Waiting For, Next Actions, Someday/Maybe) also offers a `Re-clarify…` action that opens the full clarification UI as a sub-flow over the current item; routing inside the sub-flow advances the cursor, while backing out without routing keeps the item and advances. Every list-driven step (Inbox, Waiting For, Next Actions, Someday/Maybe) auto-skips on entry when its snapshot loads empty. Tapping Done finalises the completion timestamp (synced across devices) and returns the user to the inbox.
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
* **Import from Nirvana:** One-time migration of tasks, projects, contexts, and metadata from Nirvana GTD export, preserving GTD state and hierarchy.

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

* **Engineering:** Prioritize Local-First data storage to eliminate UI latency. Manage the state transitions (Scheduled -> Next Action) and focus tracking (`focus_sessions.current_task_id`) rigidly to ensure accurate time logging.
* **Design:** Maintain a strict visual dichotomy. High information density for the GTD Inventory (planning phase) and extreme minimalism for Focus Mode (execution phase). Ensure Guardrail interruptions are clear, explaining the *why* behind the restriction.
* **Optional Authentication:** The app must be fully functional without login. Authentication is only required for cross-device sync via PowerSync. Users can operate indefinitely in local-only mode, with opt-in sign-up to enable sync. Local data must be preserved and migrated on first sign-in.
* **Sync:** Real-time bidirectional sync between local SQLite (Drift) and PostgreSQL via self-hosted PowerSync. The sync layer activates only after authentication and must handle offline write queuing and conflict resolution (last-write-wins for v1).
* **Cross-Device Settings Sync:**
    * **Storage:** User preferences (sprint/break durations, planning time, notification and banner toggles, snooze duration) and ceremony state (banner dismissed, notification skip/snooze, Evening Shutdown check-in completed — see Epic 2) are stored in the `user_preferences` table and replicated across devices via PowerSync. Sprint timer ephemeral state (current phase, end-time, sprint/break counters) remains in `SharedPreferences` only and is not synced.
    * **Source of truth:** `syncedPreferencesProvider` is the single source of truth for synced preferences; providers that derive state from preferences watch it via `ref.listen` and re-derive state automatically when remote changes arrive via PowerSync.
    * **Migration:** On the first app launch after upgrade, a one-time migration copies the following known keys from `SharedPreferences` into the Drift `user_preferences` table: settings keys (`focus_settings_sprint_duration_minutes`, `focus_settings_break_duration_minutes`, `focus_session_planning_settings_time_hour`, `focus_session_planning_settings_time_minute`, `focus_session_planning_settings_notification_enabled`, `focus_session_planning_settings_banner_enabled`, `focus_session_planning_settings_default_snooze_duration`) are moved and cleared from `SharedPreferences`; ceremony keys (`planning_banner_dismissed_date`, `planning_notification_skipped_date`, `planning_notification_snoozed_until`, `shutdown_ritual_completed_date`, `shutdown_banner_dismissed_date`, `shutdown_notification_skipped_date`, `shutdown_notification_snoozed_until`) are copied but retained in `SharedPreferences` for cold-start reads.
