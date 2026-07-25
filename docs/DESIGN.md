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
minimal chrome. Capture is the one slot still to fill (`pinnedAction`, #458).

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
    Identical position on every screen; never overflows.
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
*   **Current-action anchor row** — the current Action's text with a leading filled marker and a trailing down-arrow **"Move to plan"** demote button. When the Outcome is **Actionless**, a quiet `No current action` placeholder holds the slot — the empty state that makes promotion meaningful.
*   **Planned queue** — a `ReorderableListView` with per-row explicit drag handles (so taps stay free for inline editing). Each row shows the planned Action text (tap to edit in place, save on focus-loss — the screen's inline-edit idiom), an up-arrow **promote** affordance, and a **remove** (×) affordance. Reordering writes the new dense order.
*   **Add affordance** — an inline `+ Add planned action` row (primary blue) that expands into a text field; submit appends a planned Action. No SnackBars — every affordance is inline.

**Promotion copy is honest about supersession.** With no current Action the up-arrow promotes directly. With a current Action it opens a bottom sheet naming both Actions and a single **"Replace current action"** confirm (supersede-and-promote) — never a silent replace. **Empty states** use CONTEXT.md vocabulary verbatim: **Planless** (no current, no planned) shows the placeholder anchor plus `No plan yet — add the actions you're thinking of.`; a current Action with an empty queue shows just the add affordance under the anchor.
