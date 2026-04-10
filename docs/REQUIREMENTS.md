# Product Requirements Document (PRD): GTD Execution Hybrid App

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

### Epic 2: The Daily Execution Layer
**Goal:** Prevent overwhelm by filtering the GTD inventory into a manageable daily plan.
* **Daily Planning Ritual:** A guided workflow forcing users to review 'Next Actions'/'Scheduled' lists and select tasks for the current day.
* **Bi-Directional Calendar Sync:** Split-screen UI. Left side: Today's selected tasks. Right side: Calendar (Google/Apple/Outlook sync). Users drag tasks onto the calendar to create timeboxes.
* **Capacity Warning:** Visual indicators (e.g., progress bars or red text) if the total estimated time of selected tasks exceeds the available free time on the synced calendar.
* **Focus Mode:** A minimalist execution UI that hides all other system lists and shows only the active task.
* **Evening Shutdown:** End-of-day prompt to review completed work against estimates and roll over incomplete tasks.

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

---

## 4. Prioritization Roadmap

| Phase | Focus | Target Epics | Rationale |
| :--- | :--- | :--- | :--- |
| **Phase 1: Core Engine** | Data Model, Basic CRUD, Bi-Directional Calendar Sync | Epic 1, Epic 2 | Highest technical risk and foundational necessity. The app fails without a stable database and reliable calendar sync. |
| **Phase 2: Execution Loop** | Pomodoros, Resolution Matrix, Guardrails | Epic 3, Epic 4, Epic 5 | The core differentiator (80/20 value). Guardrails must be deployed before beta testing to prevent garbage data accumulation. |
| **Phase 3: OS Hooks** | Share Sheet, Geofencing, Time Filters | Epic 6, Epic 7 | High value, moderate effort. Improves capture flow and contextual filtering. |
| **Phase 4: Intelligence** | AI Triage, Conversational Capture | Epic 8 | Highest latency/cost risk. Treat as a progressive enhancement built on top of the solid manual workflows. |

---

## 5. Architectural Directives

* **Engineering:** Prioritize Local-First data storage to eliminate UI latency. Manage the state transitions (Scheduled -> In Progress -> Deferred) rigidly to ensure accurate time tracking.
* **Design:** Maintain a strict visual dichotomy. High information density for the GTD Inventory (planning phase) and extreme minimalism for Focus Mode (execution phase). Ensure Guardrail interruptions are clear, explaining the *why* behind the restriction.
