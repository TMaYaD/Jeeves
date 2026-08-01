# 0044 — Most integrity alarms are reports, not errors

**Status:** accepted (2026-08-01)

Exactly one of the eighteen alarm kinds — `author_chain_gap` — has any code path
that can clear it. The other seventeen can only be raised, so the subsystem is
effectively write-only and every alarm it raises is immortal from the moment it
fires. Beside that, `SyncHealth.degraded` counted *every* unresolved alarm and
*every* unreleased quarantine row. The two together produced the defect this ADR
exists to fix: a device painted itself permanently red for conditions it had
handled perfectly — a forged envelope it correctly refused, a reorder that healed
and converged, a KeyWrap that had simply not arrived yet. The user-facing surface
for all eighteen was one red cloud icon with the tooltip `Sync error`, and nothing
rendered a `kind`, a `detail` or a refused byte: the counts reached the UI and the
reasons did not. A red indicator the user can do nothing about is what trains them
to ignore red indicators.

**Each kind now carries a `SyncConditionClass` — `actionable`, `reported`, or
`transient` — decided at design time and stored nowhere.** Four kinds are
`actionable`: `author_chain_gap`, `own_writes_rollback`,
`own_write_refused_permanently`, `epoch_key_set_unpublishable`. Those four, and
only those four, make the indicator an error. Fourteen are `reported`: the app did
the right thing and nothing is at risk. Five refusal reasons are `transient` —
delivery gaps that heal by themselves — and are surfaced nowhere at all. The class
is a property of the **kind**, never a state a gesture can set, which is what keeps
this from being dismissal wearing a different hat: dismissal was proposed and
rejected, because the product must not offer silence as an outcome, and because
"dismiss" has no meaning for a conflict that is genuinely unsettled. Because the
class is computed from the stored code, there is no column, no migration and no
retention question. Adding a kind without deciding both its class and what it says
is a compile error, so the next kind cannot arrive as an error by default.

Two more things are settled here, and recorded as decisions rather than as
accidents a later reader should tidy up. First, **the calm band takes amber
(`#F59E0B`) with a distinct glyph** (`cloud_done_outlined` against healthy's filled
`cloud_done`): both tone and shape differ, because colour alone collapses under
deuteranopia at 20px. Amber is therefore *spent* on report-only conditions — when
the deferred resolution model returns, "a resolution is in flight" cannot be amber
and should probably not be a colour at all, since transience is carried better by
motion or an inline row-level treatment than by a hue that has to be memorised.
Second, **there is deliberately no way to check sync health while healthy.** The
screen is reachable only when there is something to report; a permanent entry point
is a standing invitation to worry about a subsystem that is working, and a second
presentation of sync state is exactly where the last untruth lived (the deleted
Settings tile that read "Sync active" on a device syncing nothing).

The price is paid in two places, both accepted. A user cannot ask "is sync OK?" on
demand — they can only be told when it is not, which is the trade named above.
And `compaction.dart`'s blocker still gates on `unresolvedAlarmCount`, which still
counts `reported` alarms: a Workspace served one forged envelope still cannot
compact. That is correct on its own terms — a device must not snapshot state it has
accused — and it is #654's substance rather than this ADR's. **This change fixes the
indicator, not the log.** All resolutions (`tookUpstream`, keep-ours,
reject-permanently), `SyncStatus.resolving` and the outbox-grounded in-flight state
are deferred with #575, which stays open; #584's reporting surface is what ships.
