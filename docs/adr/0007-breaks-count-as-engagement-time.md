# Breaks count as engagement time

The TimeLog runs continuously from when the user starts engaging with an Action to when they stop. Pomodoro Sprint↔Break transitions do not close it. As a consequence, **Break time is counted in the Outcome's total time-spent** — there is no per-row distinction between "active" Sprint clock and "rest" Break clock.

Many productivity tools take the opposite stance — Breaks are deducted, "time spent" reflects only the Sprint clock. We considered and rejected that model.

A Break is not a gap in engagement — it is part of the engagement rhythm. Mid-Sprint distractions are abandonment (Stop), not Breaks; a Break is a deliberate choice in service of the next Sprint. Excluding Break time would force the model to distinguish "real" engagement from "support" engagement, a brittle split that invites edge cases (does a stretching break count? a snack run? a bathroom break? a Slack reply?). Counting all clock time spent in the engagement loop keeps the boundary clean: TimeLog measures wall-clock engagement, period.

This decision also follows directly from the no-pause invariant ([#246](https://github.com/TMaYaD/Jeeves/issues/246), PR [#252](https://github.com/TMaYaD/Jeeves/pull/252)): once we ruled out a clock-suspension state, the only consistent treatment of Breaks is to count them. A reader of the schema who sees `time_logs` rows spanning Pomodoro cycles without internal subdivision is looking at this decision in effect.
