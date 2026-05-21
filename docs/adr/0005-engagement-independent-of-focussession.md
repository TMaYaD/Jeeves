# Engagement independent of FocusSession

FocusSession is the recommended discipline — Planning → Execution → Review wraps engagement in a curated environment. The act of engagement itself (doing the current Action, logging time) could either require an open FocusSession (gating) or happen ad hoc with or without one (additive).

Engagement is independent of FocusSession. The user may engage with any Outcome from any List at any time; if a FocusSession is open at engagement time, the TimeLog attributes to it (and to off-Plan engagement, per ADR-0002); if no FocusSession is open, the TimeLog is ad hoc with a null session FK.

The FocusSession's purpose is to *create* an environment for engagement, not to *impose* it. Gating engagement on a session bypasses GTD's canonical model (ad-hoc Next Action picking by context, energy, and time is the normal mode), creates attribution edge cases (orphan engagement vs degenerate auto-created sessions), and conflates the discipline overlay with the underlying act. The cost of supporting ad-hoc engagement is a nullable session FK on TimeLog — trivial. The benefit is that the system's discipline does not impede the doing.
