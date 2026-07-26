# ADR-0023: Clarification never rewrites the Capture

**Status:** Accepted
**Date:** 2026-07-26
**Context:** Issue #455 (clarify-surface deduplication). Builds on ADR-0006 (Capture/Outcome split).

## Decision

**The clarify surface never writes a Capture's `title` or `notes`.** The fields seed from the Capture and feed the Outcome draft; the Capture keeps exactly what was captured. Clarification *produces* structure from raw input — it does not edit the input.

This corrects a divergence between the code and the model. `CONTEXT.md` defines a Capture as "a raw, unprocessed fragment" that "persists as provenance for the Outcomes it clarified into", yet the clarify card was rewriting `captures.title` / `notes` as the user typed. The raw record was being overwritten by the interpretation of it, so what the system kept as "what I captured" was no longer what was captured.

**An Outcome subject's text edits save normally.** The re-clarify surface writes an Outcome's title and notes on focus loss, as task detail and active focus already do. Editing an Outcome is ordinary editing; the provenance argument does not reach it, and making this one surface behave differently would be an inconsistency with no reason behind it.

**Because a Capture's text is never persisted, the in-progress draft is retained in memory.** An injected store keyed by Capture id holds it, so stepping Back and forward within a Ceremony performance keeps the user's typing. Retention exists *only* for Captures — an Outcome's edits persist, so there is nothing to retain. The draft is discarded when the Capture reaches a verdict, when a performance completes or resets, and at process death. Skip does not discard it. Surfaces with no in-flow navigation — the standalone `/inbox/:id/clarify` screen and the Re-clarify route — receive no store, so the absence is structural rather than conditional.

Tag hints are unaffected: they persist to `capture_tags` at capture time and during clarification, which `CONTEXT.md` already records as the deliberate exception — a hint is a suggestion recorded alongside the fragment, not a rewrite of it.

## Trade-off

The cost is that the Inbox shows what you captured, not your working copy. Correct a typo mid-clarify and Skip, and the Inbox still shows the typo; the correction lives in the retained draft and lands on the Outcome when you route. We accept that: the Inbox is a list of raw fragments awaiting clarification, and a fragment that silently rewrites itself as you look at it is the stranger behaviour.

We also accept losing an in-progress Capture draft to process death and to a ceremony reset — it was never a persisted thing to begin with.

The rejected alternative was **writing the Capture once, at the verdict** rather than continuously. That reduces the provenance damage without removing it, and it answers the wrong question: the issue was never *when* the raw record is overwritten but *that* it is.

Worth recording for anyone tempted to reinstate autosave: the durability it appeared to provide was partly illusory. The `dispose()` half — covering "typed something, left before the debounce fired" — never executed at all, because it called `ref.read` from `dispose()`, which throws once the element is defunct (#529, fixed 2026-07-26). The case a user would most notice was already broken and silently swallowed by an `unawaited` write.
