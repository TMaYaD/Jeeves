# Scratchpad - Remove overscroll in Clarify Step

## Current Goal
- [x] Remove overscroll from all daily planning screens
- [x] Remove toast messages (SnackBars) from all planning steps

## Blockers
- None

## Notes
- User requested removing overscroll.
- Found `ListView` in `InboxClarificationStep`'s `_ClarifyCard` widget.
- Will apply `ClampingScrollPhysics` to the `ListView`.

## Last Spec Read
- 2026-04-16 09:52 (Conversation started)
