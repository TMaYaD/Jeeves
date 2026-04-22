# Design System Document

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document outlines the core aesthetic and functional principles of our design system.

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
Our UI elements feature **maximum, pill-shaped (3)** roundedness, contributing to a soft and approachable aesthetic.

### Spacing
We maintain a **normal (2)** level of spacing, balancing information density with visual comfort and ease of use.
