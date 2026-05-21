# Action as a first-class entity

Proposal `docs/proposals/blockers-and-contexts.md` §6 / [#185](https://github.com/TMaYaD/Jeeves/issues/185) framed "NextAction" as a lightweight cursor — a text field on the Outcome plus supporting metadata, no separate entity, no lifecycle, no history. That framing was the path-of-least-resistance to ship Blockers without re-opening the entity question; it was a sidestep, not a settled design.

We are reversing it. Action is a first-class entity with identity, a four-role lifecycle (`planned` / `current` / `done` / `superseded`), supersession as a row (not in-place edits), and TimeLog attribution at the Action grain.

The cursor model collapsed fields that conceptually belong to *the action of doing* (energy, time estimate, time spent, waiting-for) onto the Outcome row, eroding the outcome-vs-action distinction the rest of the model now depends on. Promoting Action preserves per-action metadata, keeps the chain of past Actions as the Outcome's history for retrospection and AI augmentation, and lets TimeLog attach where engagement actually happens.
