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
* **System Views:** Auto-generated lists for 'Next Actions', 'Waiting For', 'Scheduled', and 'Someday/Maybe'.
* **Sequential Logic:** Support for project dependency tracking. A 'Next Action' must remain hidden until its prerequisite task is marked complete.
* **Context Tag Cloud:** A sticky, multi-select tag filter in the primary navigation drawer. Each chip shows the context name and its active-task count; chip weight (size/opacity) reflects relative count. Selecting one or more chips filters all list views to tasks carrying **all** selected tags (AND semantics). The filter persists across screen navigation until explicitly cleared. Long-pressing a chip opens tag management (rename, recolour, merge).

### Epic 2: The Daily Execution Layer
**Goal:** Prevent overwhelm by filtering the GTD inventory into a manageable daily plan.
* **Daily Planning Entry:** The ritual is never auto-launched on app open. Users are nudged through two opt-in mechanisms:
    * **Persistent banner:** A dismissible "Plan your day →" banner shown at the top of all main views until the ritual is completed or dismissed for the day. Configurable via Settings.
    * **Scheduled notification:** A local push notification at the user's configured planning time (default 08:00) with actions — Open, Snooze (configurable duration: 15 min / 1 hr / tomorrow), and Skip today. Skip suppresses all nudges until the next calendar day. Snooze reschedules a one-off notification. All state persists across app restarts.
    * Settings: planning time, default snooze duration, enable/disable notification, enable/disable banner.
* **Daily Planning Ritual:** A guided 6-step workflow:
    1. **Clarify Inbox (Step 1):** Process every inbox item before queueing work. For each item, the user answers "What's the expected outcome?", sets fields (energy level, time estimate, due date), and routes it to the correct GTD list (Next Action, Scheduled, Waiting For, Someday/Maybe, or Done). Advancing is gated on an empty inbox.
    2. **Day Check-in (Step 2):** User reports today's energy level (Low / Medium / High) and available time (hours + minutes).
    3. **Review Next Actions (Step 3):** Swipe-card review of unreviewed next-action tasks — select for today, skip, or defer to Someday/Maybe.
    4. **Today's Schedule (Step 4):** Confirm or reschedule tasks that are due today.
    5. **Time Estimates (Step 5):** Set time estimates on any selected task that is still missing one.
    6. **Today's Plan (Step 6):** Summary showing tasks sorted by priority — due date (ascending) → scheduled → next actions. Capacity bar warns if planned time exceeds available time. "Start Day" finalises the plan.
* **Bi-Directional Calendar Sync:** Split-screen UI. Left side: Today's selected tasks. Right side: Calendar (Google/Apple/Outlook sync). Users drag tasks onto the calendar to create timeboxes.
* **Capacity Warning:** Visual indicators (e.g., progress bars or red text) if the total estimated time of selected tasks exceeds the available free time on the synced calendar.
* **Focus Mode:** A minimalist execution UI that hides all navigation and lists, showing only the active task. Activated via a "Start" button on any task in the daily plan. Displays the task title, notes, an elapsed timer (HH:MM:SS), and an action bar with Pause, Complete, and Abandon. Complete transitions the task to `done` and returns to the daily plan; Abandon transitions to `deferred` and returns to the daily plan; Pause freezes the timer (task stays `inProgress`). A persistent notification appears when the app is backgrounded during focus. If the app is restarted mid-session the timer is restored from the `inProgressSince` DB field.
* **Evening Shutdown:** End-of-day guided ritual to review completed work against estimates, resolve each unfinished task (roll over to tomorrow, return to next actions, or defer to Someday/Maybe), view daily summary stats, and close the day. Triggered at a user-configured time (default 18:00) via a local notification and a dismissible banner. Available manually from Settings.

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
    * **Defer (Log & Park):** Log 20 mins, mark task "In Progress," remove from today's plan, and return it to 'Next Actions'.
* **Estimation Analytics:** System tracks the delta between estimated and actual pomodoros to improve future AI estimations.

### Epic 5: System Integrity & The Review Guardrails
**Goal:** Prevent inventory rot through behavioral nudges and progressive friction.
* **System Trust Score:** Background monitoring of inventory health (unprocessed inbox items, stale tasks, overdue reviews).
* **Progressive Restriction:**
    * **Level 1:** Persistent UI banner if the Weekly Review is missed.
    * **Level 2:** If Weekly Review is >48 hours overdue, or Inbox >50 items, the Daily Planning workflow (Epic 2) is disabled until the backlog is cleared.
* **Guided Review Wizard:** A low-friction, step-by-step UI for the GTD Weekly Review (Zero Inbox -> Brain Dump -> Review Waiting For -> Review Projects -> Review Someday/Maybe).
* **Stale Task Sweeper:** Forces a binary choice (Move to Someday/Maybe OR Delete) on tasks bypassed/rescheduled more than three times.

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
| **Phase 1: Core Engine** | Data Model, Basic CRUD, Bi-Directional Calendar Sync | Epic 1, Epic 2 | Highest technical risk and foundational necessity. The app fails without a stable database and reliable calendar sync. |
| **Phase 2: Execution Loop** | Pomodoros, Resolution Matrix, Guardrails | Epic 3, Epic 4, Epic 5 | The core differentiator (80/20 value). Guardrails must be deployed before beta testing to prevent garbage data accumulation. |
| **Phase 3: OS Hooks** | Share Sheet, Geofencing, Time Filters | Epic 6, Epic 7 | High value, moderate effort. Improves capture flow and contextual filtering. |
| **Phase 4: Intelligence** | AI Triage, Conversational Capture | Epic 8 | Highest latency/cost risk. Treat as a progressive enhancement built on top of the solid manual workflows. |
| **Phase 5: Behavioral Layer** | Habits, Extended Capture | Epic 9, Epic 10 | Expands the system from task management into holistic productivity. Habits address the recurring-task workaround users already employ. |
| **Phase 6: Portability** | Import/Export, Migration | Epic 11 | Reduces onboarding friction for users switching from other GTD tools. |

---

## 5. Architectural Directives

* **Engineering:** Prioritize Local-First data storage to eliminate UI latency. Manage the state transitions (Scheduled -> In Progress -> Deferred) rigidly to ensure accurate time tracking.
* **Design:** Maintain a strict visual dichotomy. High information density for the GTD Inventory (planning phase) and extreme minimalism for Focus Mode (execution phase). Ensure Guardrail interruptions are clear, explaining the *why* behind the restriction.
* **Optional Authentication:** The app must be fully functional without login. Authentication is only required for cross-device sync via PowerSync. Users can operate indefinitely in local-only mode, with opt-in sign-up to enable sync. Local data must be preserved and migrated on first sign-in.
* **Sync:** Real-time bidirectional sync between local SQLite (Drift) and PostgreSQL via self-hosted PowerSync. The sync layer activates only after authentication and must handle offline write queuing and conflict resolution (last-write-wins for v1).
