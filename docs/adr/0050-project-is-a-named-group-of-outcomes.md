# Project is a named group of Outcomes

A **Project** is a name the user gives to a group of Outcomes. An Outcome is assigned to at most one Project, and its Project and its Area are independent of each other. An Outcome that needs several Actions has no special name. This supersedes [ADR-0003](0003-no-multi-outcome-project-composition.md), which defined Project as a derived classification of multi-Action Outcomes.

The meaning changed because the app already ships Project as a named group — the Project page, the Project picker, Settings → Manage, bulk assignment from lists and the Nirvana import — while the derived classification was never surfaced anywhere. Stories written against the app ("assign to a Project") could not be read against the glossary. The board owner settled it in the day-timeline design review by keeping the app's meaning.

What survives from ADR-0003: there is still no parent-child Outcome tree. A Project is a flat group and is not itself an Outcome, so this decision is not approval for nested Outcomes.
