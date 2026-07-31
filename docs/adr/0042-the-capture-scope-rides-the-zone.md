# 0042 — The capture scope rides the zone, not a stack or a parameter

`GtdDatabase.capturing` opens its capture scope as its first *synchronous*
statement, while its body cannot run until drift's `transaction` has awaited
`ensureOpen`. Two un-awaited `capturing` calls therefore **always** both open
their scope before either body runs — and the production UI issues exactly that
shape, since the clarify card fires un-awaited top-level domain writes, so two
quick taps produce it. A seam that filed a described effect into "the scope begun
most recently" put the first caller's writes into the second caller's buffer, and
parented a nested scope to a stranger. That reopened both of the directions #598
closed: the **phantom**, where the first caller rolls back
and the second signs its write anyway — reduced and projected back into the very
store the rollback emptied, then replicated to every peer — and the **loss**,
where the first caller *commits* and the second then throws, so
`rollbackScope` clears its buffer along with the committed caller's op. That
second one is a committed local row with no op, for ever: invisible and
unrecoverable.

The live scope therefore **rides the zone `capturing` already opens**, per seam
instance: `runInScope(scope, body)` makes it ambient, the write verbs and
`beginScope` both read it there, and the stack of open scopes is gone. A
described effect with no ambient scope, or one whose scope has already closed,
**throws** — it is never dropped, because a dropped op is precisely the
unrecoverable failure above, while a throw is loud and local to the call site
that caused it. `uncapturedTransaction` and schema migrations run with the
ambient scope masked (`null`), which makes their "authors nothing" enforced
rather than incidental.

The alternative the issue originally prescribed — **thread a scope handle through
the write verbs** — cannot fix parenting: `beginScope()` takes no arguments, so
making a nested scope's parent explicit means a viral optional parameter on
`capturing` through 56 call sites and on every public DAO method as well as the
31 write sites, and every such parameter is forgettable — a forgotten one being
silently the misattribution being fixed. **Serialising `capturing`** was rejected
because it is re-entrant through public DAO methods, so a FIFO lock deadlocks on
the nested call; the `EnrolmentService._runCeremonyExclusive` idiom works only
because a locked wrapper there sits over an unlocked core, and here the outer and
inner caller are the same method. Zero call-site churn is the decisive property,
not a bonus: import-path write sites are still being added, and a fix that
enumerated today's callers would be wrong the moment they land. The cost accepted
in exchange is that attribution is implicit, and so invisible at the call site;
what makes it safe is that every write verb is a synchronous statement inside a
DAO body, nothing in the write paths escapes its zone via `unawaited`, a timer, a
microtask or an isolate, and drift's own forks are additive `runZoned` calls.

**A standing constraint, because this defect is one hop from a confidentiality
breach.** `WorkspaceRoutingOpCapture` picks its destination client purely from
`op.collection` — the collection is an argument to the write verbs, stored on the
`CapturedOp` and re-slotted by the merge path — and **never** from scope state.
`capturing` and `beginScope` carry no Workspace identity, and no Workspace
switcher exists. That map is the only thing that kept misattribution a
correctness bug rather than a disclosure one: routing the destination client off
scope state, or introducing a second GTD-class Workspace (a shared or team
Workspace) that shares one seam instance, would seal domain data to the wrong
Workspace's members. Either change requires revisiting this ADR. Related and
still open: `SyncClient._authorAndQueue` stamps `workspaceId` from the client's
own field with no subject-versus-Workspace validation.
