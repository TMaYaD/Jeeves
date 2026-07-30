# 0036 — The capture seam buffers until the enrolment decision

The domain capture seam (`WorkspaceRoutingOpCapture`) is constructed at process
start, before sign-in and before the enrolment status has been read, while the
lifecycle that binds it runs a chain of async work — session restore, sync-store
open, and a proof-of-possession network round trip — before it reaches its bind
step. Under ADR-0034 ("sync starts at enrolment"), any DAO write in that window
was described through the seam and silently dropped; on a store whose initial-
upload marker is already set, the drop was permanent, because the marker gates the
walk that would otherwise re-carry the row. Post-flip that is live data loss to
the log, and an offline enrolled relaunch — where the PoP throws — dropped *every*
write of the session.

The seam therefore holds a **tri-state decision** (undecided → bound | silent),
not a bound/unbound flag: while undecided it *buffers* the ops it is handed, and
what disposes of a buffered op is the enrolment **decision**, never launch timing.
The lifecycle makes that decision from local reads alone and binds *before* any
network step, so the decision cannot wait on the PoP; binding drains the buffer in
write order, an un-enrolled or signed-out device settles the seam silent (which
discards the buffer), and the PoP moves inside the sync `try` so an offline
relaunch classifies as `syncFailed` with capture already bound rather than
escaping unclassified.

The alternatives were to **gate writability on activation** — hold the first
frame until the sync-side reads finish, which inverts the recorded stance that
startup work must not block the UI and adds UI machinery for a data-integrity
concern — or to **only reorder, without buffering**, which shrinks the loss window
from network-unbounded to local-async but leaves a fast first write (or the
expired-token restore path) still able to fall through it. Buffering is the only
option that closes the window airtight, because the seam's construction site is
the one point that provably precedes every write. The decision being made from
local reads (never a network answer) is load-bearing: a decision that waited on
the network would reopen exactly the window this closes. Supersedes nothing;
refines the activation ordering ADR-0034 established.
