# Design System Document

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document outlines the core aesthetic and functional principles of our design system.

## Reference design prototypes

Two claude.ai/design projects are the canonical UX references for the execution-layer experience. Epic-level design work extends them; new surfaces must match their design language (and this document's tokens):

| Project | Covers |
|---|---|
| [Jeeves — Focus Mode](https://claude.ai/design/p/e324ad40-21d8-4572-b90c-5356cc0839ce?file=Focus+Mode.html) | Mobile execution surfaces: Today's Plan list, Focus Mode sprint ring (Monastic / Paced / Instrument variants), sprint-resolution bottom sheet (Complete / Extend / Defer), Break, Task-complete — in light and dark themes, with tag-density options. |
| [Jeeves — Daily Execution Layer](https://claude.ai/design/p/6a1ed3d8-1b97-4abd-8f45-0315ca69bc07?file=Jeeves+Daily+Execution+Layer.html) | The full desktop day loop (1440px sidebar shell): Morning planning (clarify → energy → selection → estimates) → Agenda → Timebox timeline → Focus → Shutdown (dispositions + journal), plus a mobile companion panel. Also the desktop-layout reference for cross-platform work. |

Both are accessible via the claude_design MCP (`https://api.anthropic.com/v1/design/mcp`, auth via `/design-login`).

### Epic-level design precedes stories

Every epic carries a **Design** section in its GitHub issue: one epic-level UX design pass, produced with the design skill in claude.ai/design, covering all surfaces the epic's stories touch. Child stories do not begin UI implementation until that pass is published and reviewed. This keeps the experience coherent across stories instead of accreting per-story patches.

## Brand

### Logo marks

Two marks, one brand — choose by context, not preference:

| Mark | Role | When to use |
|---|---|---|
| **Pointillist** | Primary | Anywhere pastels render ≥ 32 px: app icon, onboarding, splash, marketing, large chrome |
| **Signature** | Backup | Single-colour contexts, dense UI ≤ 32 px, favicons, monochrome print |

### Design tokens

```
INK    #1A1A2E   — base text / dark background
BRAND  #2667B7   — Jeeves Blue; always the Signature tittle
WHITE  #FFFFFF

Pointillist dot palette (top→hook order):
  brand  #2667B7   sky  #60A5FA   lav  #C4B5FD
  peach  #FDBA74   blush #F9A8D4  mint #6EE7B7
  butter #FDE68A

Wizard footer tokens:
  SKIP_GREY      #6B7280   — Skip button foreground (de-emphasised escape hatch)
  ACCENT_WEEKLY  #059669   — Weekly Review accent (emerald)
  ACCENT_DAILY   #2563EB   — Daily Planning accent (blue)
```

### Canonical source files

`app/assets/brand/` contains the eight authoritative SVGs:

| File | Description |
|---|---|
| `logo-pointillist.svg` | 7-dot mark, transparent, light surface |
| `logo-pointillist-on-dark.svg` | same + per-dot `rgba(255,255,255,0.85)` hairline |
| `logo-pointillist-appicon.svg` | dots on INK rounded-square plate (256 viewBox, rx=56) |
| `logo-signature.svg` | Calligraphic j, INK stem + BRAND tittle, transparent |
| `logo-signature-on-dark.svg` | WHITE stem + BRAND tittle, transparent |
| `logo-signature-appicon.svg` | WHITE stem + WHITE tittle on BRAND plate |
| `wordmark-light.svg` | Pointillist + "Jeeves" (Manrope 700, INK) |
| `wordmark-dark.svg` | Pointillist-on-dark + "Jeeves" (Manrope 700, WHITE) |

Raster icons (`icon-source-1024.png`, `icon-adaptive-fg-1024.png`) are generated
by `tools/generate_icons.py` — treat the SVGs as source of truth, not the PNGs.

### Flutter widget — `JeevesLogo`

`app/lib/widgets/jeeves_logo.dart`

```dart
JeevesLogo(
  variant: JeevesLogoVariant.auto,  // auto | pointillist | signature | wordmark
  size: 64,                          // mark height/width in logical pixels
  onDark: null,                      // null → inferred from Theme brightness
  appIcon: false,                    // true → plated variant (INK/BRAND plate)
)
```

**Auto-swap rule:** `variant: auto` (default) selects **Signature** when
`size < 32`, otherwise **Pointillist**.

**Clear space:** the widget applies `Padding(EdgeInsets.all(size * 0.5))`
automatically. Do not add extra external padding expecting a tight bounding box.

**Minimum size:** `size >= 16` (asserted). Below 16 px even Signature is illegible.

### Usage rules (must hold everywhere)

- ✅ Clear space ≥ 0.5 × mark height on all sides (widget-enforced)
- ✅ Pointillist only at ≥ 32 px
- ✅ Signature tittle always BRAND `#2667B7`, never recoloured
- ✅ Signature stem: INK on light, WHITE on dark — use `onDark`, not ColorFilter
- ✅ On dark: Pointillist dots direct-on-background with per-dot hairline
- ❌ No stretch, rotate, outline, drop-shadow, or gradient fills
- ❌ No white plate behind Pointillist on dark surfaces

### Platform icons

App icons are generated from `assets/brand/icon-source-1024.png` using
`flutter_launcher_icons`. Re-run after any brand update:

```sh
cd app && dart run flutter_launcher_icons
```

Web icons and the 32 px favicon are produced by `tools/generate_icons.py`.

## Brand Identity

### Color Palette
Our color palette is designed for a **light** color mode, prioritizing clarity and user experience.
*   **Primary Color**: `#2667B7` - This vibrant blue serves as our main accent, perfect for calls to action and primary interactive elements.
*   **Secondary Color**: `#1E4F8F` - A deeper shade that supports the primary, used for less prominent UI components and secondary actions.
*   **Tertiary Color**: `#4A5568` - A sophisticated gray-blue accent, providing depth for highlights or decorative elements.
*   **Neutral Color**: `#4A5568` - This versatile neutral forms the foundation for backgrounds and general UI surfaces.

### Typography
Our brand font is **Manrope**, used consistently across every surface of the app. Manrope ships as an embedded variable font (`assets/fonts/Manrope-VariableFont_wght.ttf`) so the app works without internet access.
*   **Headlines**: `Manrope` - Modern and highly legible for titles and headings.
*   **Body Text**: `Manrope` - Ensures readability for all long-form content.
*   **Labels**: `Manrope` - Clear and concise for UI labels and interactive elements.

## Visual Language

### Roundedness
The canonical radii scale is the reference design system's tokens (`jeeves.css` in the Daily Execution Layer project — see Reference design prototypes above):

*   **2px** (`--radius-xxs`) — buttons: primary, soft, outline, text, icon
*   **4px** (`--radius-xs`) — chips, tags, small meta, inputs (the default small radius)
*   **6px** (`--radius-sm`) — cards, rows, sheets, and most surfaces (the default surface radius)

**Pill radii are out** — including on chips. Only genuine circles (status dots, the sprint ring) stay circular. The 8/12/16/20px values found across the shipped widgets are **migration-era legacy, deprecated for new work**; new surfaces use the 2/4/6 scale, and touched screens migrate toward it. Ruled 2026-07-16 during the epic #34/#35 design pass.

### Spacing
We maintain a **normal (2)** level of spacing, balancing information density with visual comfort and ease of use.

### Wizard footers — one forward affordance at a time
The Weekly Review and Daily Planning Ritual footers expose a single forward
affordance, never two. The footer reserves one fixed-size slot on the right
and renders exactly one button into it:

*   **Skip** — secondary, outlined, `SKIP_GREY` (`#6B7280`) foreground. Shown
    (always enabled) while the current step's per-item cursor still has items
    to consume. It advances the cursor by one; it never crosses steps.
*   **Next step** — primary `FilledButton` in the screen's accent
    (`ACCENT_WEEKLY` `#059669` for Weekly Review, `ACCENT_DAILY` `#2563EB` for
    Daily Planning). Shown when the cursor is spent, or the step has no
    per-item cursor. It crosses into the following step. It is disabled only
    while a list-driven step's snapshot is still loading.

The two are mutually exclusive and swap inside the same fixed-width, fixed-height
slot, so the button's shape, size, and position never shift across the swap.
Skip is the de-emphasised escape hatch; Next step is the emphasised path of
progress.

While the wizard's page transition is animating, the footer slot absorbs taps.
The footer swaps to the incoming step's widget the moment the step index
changes, which would otherwise put an identically-positioned forward button
under the user's finger mid-transition — a double-tap must advance exactly
one step. This absorption is part of the Wizard contract, owned by the
`Wizard` widget itself.

### Ceremony intro step — the duration-estimate briefing
The Daily Planning and Weekly Review wizards open on a shared intro step
(`app/lib/widgets/ceremony/intro_step.dart`) that sets expectations before the
numbered steps. It is a real first `PageView` step but is **excluded from the
progress-segment count** via `Wizard.leadingNonProgressSteps`: on the intro the
segmented bar renders empty and the "Step N of M" narration is suppressed
(the step passes an explicit empty subtitle), so the working steps still read
"1 of 5" / "1 of 4". Its title is neutral UI ("Before we begin"); the persona
lives in the body.

The body is a single Jeeves-speak sentence (§ Voice) with the time estimate
rendered **inline** as a bold, larger, accent-coloured run — the scannable
focal point sits inside the sentence, not stacked above it. The estimate is an
approximation: 2 minutes per item to be walked, plus a flat 5 for Daily
Planning's Energy/Time check-ins and selection (Weekly Review adds no flat),
rounded up to the nearest 5 and floored at 5 so a zero-item ceremony reads
"about 5 minutes", never "0". At zero items the copy switches to a shared
light-day pool. Copy is drawn once per performance from a seedable pool (the
`elapsed_timer_widget.dart` / `onboarding_card.dart` idiom). The proceed
control rides the standard footer's fixed slot but carries a **Bertie-speak**
label (`WizardFooter.nextLabel`, e.g. "Right ho", "Tinkerty-tonk") — the user
answering Jeeves — and is always enabled; the label shrinks-to-fit rather than
truncate. System back on the intro exits the ceremony (it is the first step);
back from the first item of the following step returns to the intro.

### Terminal verdicts share the slot the destinations vacate
Where a surface collects routing destinations *and* one terminal verdict, the
verdict occupies the slot a withheld destination leaves behind, laid out by
the same parent as the destinations — not positioned to match them by hand.
Two separately-tuned paddings drift; one parent cannot.

The clarify surfaces are the reference case. Their routing bar offers three
destinations — Next Action, Waiting For, Someday — and withholds **Done** and
**Trash** on a Capture. The Capture-level verdict renders in that vacated
slot, through the same button as the destinations, so its horizontal inset,
height, corner radius and the gap above it are theirs by construction.

Exactly one verdict shows at a time, and its label swaps with meaning rather
than splitting into two buttons behind a conditional: **"Done with this
Capture"** once the Capture has yielded at least one Outcome, **"Discard
Capture"** at zero. Each inherits the colour semantics of the slot it
occupies — `#16A34A` (routing-Done green) for the completing verdict, `#DC2626`
(routing-Trash red) for the discarding one. Discard is a legitimate
clarification verdict, not a destructive escape hatch, so it earns that slot
rather than sitting permanently beside the happy path where it would read as a
warning. Neither verdict opens a confirmation dialog.

This is the same principle as the wizard footer above — one affordance in one
slot — applied to a terminal verdict rather than to forward progress.

## Voice

Jeeves is the app's persona — a valet in the mould of P.G. Wodehouse's Jeeves;
the app speaks as Jeeves would to Bertie Wooster: deferential, unflappable,
drily witty, a step ahead. The UI is an interface TO Jeeves — the user hands
him things and he keeps them. Three registers, kept distinct:

- **Jeeves speak** — Jeeves's own utterances (onboarding, empty states, nudges,
  ceremony sign-offs, timer remarks). First person ("I/me/let me"), addresses
  the user as "sir", archaic-formal, dry understatement, no exclamation marks,
  no emoji, short. Authored as what Jeeves RECEIVES ("tell me", "leave it with
  me"), never as UI instructions ("tap the field above"). Carries a consistent
  visual treatment — inline weighted text set apart from ordinary copy: a bold
  header line (15px, w700, ink) over a lighter subtitle (w500, muted), the same
  treatment the nudge banner (`app/lib/widgets/nudge_banner.dart`) and the
  elapsed-timer `voiceStyle` (`app/lib/widgets/elapsed_timer_widget.dart`) use.
  There is no single shared Jeeves-text widget yet; each surface styles inline
  to this shape. Always written as a POOL of alternatives, one picked at random
  per occasion, so the app doesn't repeat itself — `nudge_banner.dart` (a pool
  keyed to the day) and `elapsed_timer_widget.dart` (a seedable `Random` draw)
  are the reference implementations; the onboarding card and Inbox empty state
  follow the latter (a `Random` draw, seedable for deterministic tests).

- **Bertie speak** — the USER's voice answering Jeeves: breezy upper-class
  affirmatives ("Right ho", "Push on", "Very good"). Used ONLY on an affordance
  that directly replies to a Jeeves utterance (the Daily-Planning and
  Weekly-Review nudge-banner CTAs answer Jeeves's nudge → Bertie speak). A
  control that isn't answering Jeeves (Inbox "Add", "Save", "Start fresh") is
  NOT Bertie speak — it stays neutral.

- **Neutral UI** — plain functional labels for everything that isn't Jeeves
  talking or the user answering him.

Vocabulary follows CONTEXT.md's domain terms and Avoid lists (a Capture is never
a "todo", "item", "thought", or "note").

## App title bar

One shared bar carries every screen's chrome (`AppTitleBar`,
`app/lib/widgets/app_title_bar/`; ruled in [ADR-0021](adr/0021-shared-app-title-bar.md)).
It is a `PreferredSizeWidget` mounted in `Scaffold.appBar`, configured
**entirely by constructor parameters passed top-down** — never by a provider or
`content_for`-style slot written into from below, which during a route
transition would race between the outgoing and incoming screen. Every screen
adopts it: the shell list routes (via `AppShell`, one bar keyed off route
state), task detail, clarify, settings, import, search, active focus, and the
three ceremonies (via the shared `Wizard`). The auth routes keep their own
minimal chrome. Capture rides the bar's pinned slot (`pinnedAction`, #458) on
every bar-adopting screen except the Inbox, whose `QuickAddBar` already serves
capture — the bar suppresses the pinned action there rather than present a
second, competing affordance.

### Anatomy

Left to right:

    [leading] [overline / title] [badge] … [page actions] [pinned capture] [⋮]

*   **leading** — `drawer` on the shell list routes, `back` on pushed routes,
    `none` inside a ceremony (which has no unguarded exit). The screen names
    which; the bar never inspects the router. A screen whose way out is a `go`
    or is guarded passes its own `onLeadingPressed`. A screen that must gate the
    way out while a route transition is in flight passes `leadingEnabled: false`
    — the leading renders visually disabled (`onPressed: null`) rather than
    tappable (Clarify does this while `_routing`).
*   **overline** — the small label, with an optional icon, that sits above the
    title and names what the title belongs to: the project above a task title,
    the ceremony above a step title. 12px, w600, 0.8 letter-spacing, grey
    `#6B7280`. Optional; when absent the bar is one row shorter.
*   **title** — a plain string, 20px w700 `#1A1A2E`, one line, ellipsised. It
    gets whatever width the actions leave. Screens needing richer chrome (a
    search field, a progress bar) put it in the content region flush beneath
    the bar; the bar has no below-title slot.
*   **badge** — an optional count beside the title (the Inbox's unprocessed
    count). A typed parameter, not a number smuggled into the title string; it
    costs no action slot. 4px radius per Roundedness below.
*   **page actions** — the screen's own icon actions, declared in priority
    order and laid out **ascending in priority left to right**, so the
    highest-priority action sits nearest the pinned slot. Each carries a stable
    `Key` and a label, used as its tooltip in the bar and its row text in the ⋮
    menu. An action may override its foreground colour to stay a call to action
    (task detail's Start focus keeps the primary blue `#2667B7`). A shell list
    route can supply page actions too, derived from route state and passed down
    by `AppShell` — the Now route's Re-plan action (shown only while an open
    session carries tasks) is the precedent.
*   **pinned capture** — the fixed rightmost action slot, reserved for capture.
    Identical position on every screen that pins it; never overflows. The Inbox
    is the one screen that suppresses it — its `QuickAddBar` already captures.
*   **⋮ overflow** — renders **only** when something overflowed, rightmost of
    all.

### Action budget

The number of action buttons is budgeted by **screen-width breakpoint**, not by
measured available width: a fixed budget is deterministic and testable, where
measuring creates layout feedback loops and per-device surprises.

| Width | Total action buttons (incl. the pinned action and the ⋮ when shown) |
|---|---|
| < 600 px (phone) | 3 |
| 600–1023 px | 4 |
| ≥ 1024 px (desktop) | 5 |

When the page actions plus the pinned action fit the budget, everything renders
and there is **no ⋮**. When they do not, the ⋮ claims a slot too, and how many
page actions stay in the bar depends on whether the screen pins a capture
action: with a pinned action the bar holds `budget − 2` page actions (one slot
each to the pinned action and the ⋮); without one it holds `budget − 1` (only
the ⋮ costs a slot). Either way the rest — always the lowest-priority tail —
move into the ⋮ menu in priority order. On a phone with a pinned capture: two
actions render `[Action 2][Action 1][Capture]`; three render
`[Action 1][Capture][⋮ → Action 2, Action 3]`.

Because placement moves with the breakpoint, tests never `find.byKey` a bar
action directly — see the finder helper in [TESTING.md](./TESTING.md).

Bar surfaces follow the canonical 2/4/6 scale (§ Roundedness) — the badge and
any chip in the bar are 4px, never pills.

## Interaction Patterns

### Ceremony back navigation
System back inside a ceremony mirrors the footer Back affordance — it invokes
the exact callback the active step's footer renders, retreating the per-item
cursor first, then the step. While inside the wizard the performance stays
in-progress. When footer Back is unavailable (first step, first item — or a
completion screen), system back exits the ceremony to the execution home
screen (`/focus`, user-titled "Now") — never to the launcher — and abandons
the performance. The contract is uniform across all three ceremonies and
every launch path (button, nudge banner, notification deep-link). Implemented
by `CeremonyPopScope` (`app/lib/widgets/ceremony/ceremony_pop_scope.dart`),
which wraps each ceremony screen.

### Long-press multi-select
Lists that surface batchable actions enter a multi-select mode on **long-press**, mirroring the long-press affordance the tag cloud uses for tag management. Once selection mode is active, a **contextual bar** appears immediately above the list (not in the screen-level app bar, which the shared title bar owns) showing the selected count, a per-batch preview where relevant (e.g. total planned time), a "Select all" shortcut, a Clear (×) button, and a primary commit button. Cards in selection mode replace per-row trailing actions with a leading checkbox; tapping a card toggles its membership. Deselecting the last item auto-exits the mode. Each selection toggle fires a light haptic.

This pattern is used on Step 3 (Review Next Actions) of the Daily Planning ritual to add several Pending Review tasks to today's plan in one gesture; the bar there exposes "Add to Today" as the commit button.

### Capacity bar — two-tone fill
The Plan Summary capacity bar fills in two segments. Minutes from Outcomes with a real time estimate render in the load-status tone — green (`#16A34A`) at or below 0.8 of available time, amber (`#F59E0B`) up to 1.0, red (`#DC2626`) over — keyed off the *combined* ratio so the warn/over thresholds are unchanged. Minutes contributed by selected Outcomes that carry **no** estimate (counted at the configurable default, see REQUIREMENTS Daily Planning Step 5) render immediately after them as a lighter-blue segment (`#93C5FD`, Tailwind blue-300 — same family as the Daily Planning accent `#2563EB`). The lighter blue marks that provenance; the estimate-less cards themselves look exactly like any other card (no chip). When nothing is counted at the default the bar is a single status-tone fill, unchanged. The bar keeps its 10px height, 4px corner radius, and `#E5E7EB` track.

### Outcome peek sheet
On the Daily Planning Plan Summary step, a plain **tap** on any card (Today's Plan, Pending Review, or Skipped) opens the **Outcome peek** — a read-only bottom sheet (`OutcomePeekSheet`, `app/lib/widgets/outcome_peek_sheet.dart`) surfacing the Outcome's fuller context: title, notes, energy, time estimate, due date, and time logged. It is read-only by construction (Text/icon rows only — no fields, pickers, or edit navigation) and writes nothing, so opening or dismissing it never selects, skips, or otherwise mutates the plan; the modal sits over the never-unmounted list, so scroll and selection are preserved on dismiss. Time logged is summed from the `time_logs` table, not the `time_spent_minutes` cursor.

Tap and long-press are split by mode: **tap peeks, hold selects**. Long-press enters multi-select (above); while multi-select is active, tap reverts to its selection meaning on Pending cards and the peek is unavailable — tap is inert on Today's Plan / Skipped cards, whose action buttons stay fully functional. Exiting multi-select restores tap-to-peek. The sheet follows the 2/4/6 radii scale — 6px top corners (sheet surface), 4px meta chips.

### Task-detail Plan section
The task-detail screen (`/task/:id`) carries a **Plan** section (`_PlanSection`, `app/lib/screens/task_detail/task_detail_screen.dart`) above the Notes area — the Outcome's "what's next" outranks free-text notes. Its anatomy, top to bottom:

*   **Section label** — a `PLAN` overline styled like the `NOTES` label (12px, `#9CA3AF`, tracked caps) with a checklist icon.
*   **Current-action anchor row** — the current Action's text with a leading filled marker and two trailing controls: a down-arrow **"Move to plan"** demote button and an archive-glyph **"Abandon"** button. Both render only when a current Action exists. When the Outcome is **Actionless**, a quiet `No current action` placeholder holds the slot — the empty state that makes promotion meaningful.
*   **Planned queue** — a `ReorderableListView` with per-row explicit drag handles (so taps stay free for the row's own tap target). Each row is two lines: the planned Action text, then its **effort meta line** — an energy chip (`#7C3AED`, bolt glyph) and a time-estimate chip (`#2563EB`, timer glyph), or, when the row carries neither, a quiet `Set` prompt in `#9CA3AF`. Trailing the row are an up-arrow **promote** affordance and a **remove** (×) affordance. Reordering writes the new dense order.
*   **Planned-action sheet** — tapping anywhere on a planned row's body opens a bottom sheet carrying the Action's phrase and both effort pickers; `+ Add planned action` opens the same sheet empty. It reuses the clarify surfaces' `ClarifyEnergyPicker` and `ClarifyEstimateChip` over the shared `kEstimateOptionsMinutes` ladder, so effort means the same thing wherever it is set. The confirm button (`Add` / `Save`) is disabled while the phrase is blank; dismissal cancels silently, matching the Replace and Abandon sheets. **A blank phrase never deletes a row** — in edit mode it only parks the sheet un-confirmable, and dismissing leaves the row's text as it was. Removing a planned Action is the × and nothing else.
*   **Add affordance** — an inline `+ Add planned action` row (primary blue) that opens the sheet. No SnackBars — every affordance is inline.

**The effort chips are read-only by construction**, the same structural guarantee the history rows carry: `MetaChip` contains no gesture, icon button or field, so the row's single tap target is the ancestor covering its whole body. There is exactly one way to change a planned Action's effort, and it is the sheet.

**The current-action anchor row carries no chips and no sheet.** Its effort is edited by the Outcome-level energy and estimate editors further down the screen, which write through `TodoDao.updateFields` — the only writer that keeps the Outcome's mirror columns in step with the current Action (`docs/ARCHITECTURE.md`, D1). Routing the anchor row through the planned sheet would write the Action alone and leave the columns holding the old values, which resurface the moment the Action is abandoned. Two alternatives were rejected: giving the anchor row the same sheet (breaks D1 as described), and giving planned rows inline pickers instead of a sheet (three controls per row does not fit a 320dp row, and the effort attributes are set together far more often than separately).

**Promotion copy is honest about supersession.** With no current Action the up-arrow promotes directly. With a current Action it opens a bottom sheet naming both Actions and a single **"Replace current action"** confirm (supersede-and-promote) — never a silent replace. **Empty states** use CONTEXT.md vocabulary verbatim: **Planless** (no current, no planned) shows the placeholder anchor plus `No plan yet — add the actions you're thinking of.`; a current Action with an empty queue shows just the add affordance under the anchor.

**Abandon and Remove are different acts, and the copy says so.** **Abandon** takes the *current* Action out of play with no replacement and files it in the Outcome's history — an engaged Action leaves a record. **Remove** (the × on a planned row) hard-deletes an unengaged note that never earned one. Abandon therefore goes through a confirm sheet, the same idiom as "Replace current action": title `Abandon this action?`, the Action named under a `CURRENT` label, a line stating that it moves into the outcome's history and that nothing takes its place, and a single **Abandon** confirm button. Remove stays a bare tap. There is no un-abandon.

### Task-detail Action history
Directly under the Plan section, so the whole Action chain — what's next and what came before — reads in one place, the task-detail screen carries the Outcome's **History** (`_ActionHistorySection`, same file). It is an `ExpansionTile` styled like "Captured from…": flat (no dividers), a clock-arrow leading icon, a `History (n actions)` title in the 12px `#6B7280` section voice, **collapsed by default**, and **absent entirely** when the Outcome has terminated no Action — a fresh Outcome, or a pre-epic one whose history predates the `actions` table, shows no empty shell rather than an empty-state string.

Each row is two lines: the Action's text (14px, `#374151`), then a meta line (12px, `#9CA3AF`) reading `Done YYYY-MM-DD` or `Abandoned YYYY-MM-DD`, with ` · 25m` appended when that Action logged time. Zero minutes are omitted, not rendered as `0m`. Rows are newest-first by terminal timestamp. **No successor link is drawn** between an abandoned Action and whatever replaced it — the model stores none (ADR-0018), so the surface invents none.

**Read-only by construction.** History rows are `Text` and nothing else: no icon buttons, no tap-to-edit, no drag handles, no remove. A terminated Action is a record, so the absence of affordances is structural rather than a rule to remember — the only tap target in the section is the expander itself.
