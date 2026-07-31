# ADR-0039: Rotation ceremonies serialise through a per-User lock; resumes decline rather than wait

**Status:** Accepted (2026-07-31, issue #624)

**Context.** PR #622 (#617) made the key-rotation publish crash-resumable and,
answering a CodeRabbit review, added a fail-closed guard: `PendingRotationStore.put`
throws `ConflictingPendingRotation` when a *different* prepared set already exists
for the same `(workspaceId, toEpoch)`. That turns the orphaning race — two
ceremonies read the same epoch floor, prepare distinct sets for one `toEpoch`, and
the later `put` overwrites the earlier one whose rotate then materialises — into a
loud error instead of silent corruption. The graceful behaviour, deferred out of
#622, is for the second ceremony to *wait* for the first rather than fail. It could
not be bundled in: `rotateWorkspaceKeys` awaits `resumePendingRotations` internally,
and `resumePendingRotations` is itself a public entry point (launch resume and
pull-tail resume in `sync_lifecycle.dart`), so a naïve shared mutex re-enters and
deadlocks.

**Decision: one per-User ceremony lock on `EnrolmentService`, with two acquire
modes and a wrapper/core split.** An `EnrolmentService` instance is one User's, so a
single instance-level lock is the per-User granularity. Per-User rather than
per-Workspace is deliberate: a single `rotateWorkspaceKeys` spans *both* of a User's
Workspaces, so a per-Workspace lock would leave one ceremony holding two locks and
two ceremonies free to interleave their `prepare`/`put` on whichever Workspace
neither holds yet — the exact collision the fail-safe catches. The passphrase-gated
entry points (`rotateWorkspaceKeys`, and through it `turnOnEncryption` and
`revokeAndRotate`) take a **blocking** acquire: a second ceremony queues and runs
once the first completes, so it reads the raised floor and rotates to a fresh epoch.
`resumePendingRotations` — the public one the pull tail and launch call — takes a
**try-acquire**: if a ceremony holds or is queued on the lock it declines and returns
at once, rather than run. Each entry point is a thin locked wrapper over an unlocked
core, and the internal `rotateWorkspaceKeys → resume` call takes the core directly,
so the ceremony never re-acquires the lock it already holds.

**Why the resumes decline instead of waiting.** The pull-tail resume runs on
`SignalListener.onSyncComplete`, awaited inside the listener's single-flight sync,
and the launch resume runs inside `SyncLifecycle.activate`. If either *blocked* on a
lock a long ceremony held, it would serialise the pull loop or the whole activation
behind that ceremony — which the acceptance criteria forbid. Declining is safe:
`rotateWorkspaceKeys` resumes every stranded record for the User before it prepares
anything, so an in-flight ceremony already covers what a declined resume would have
done, and the next pull re-fires the resume once the ceremony has released. So the
two modes are not an inconsistency — a ceremony *must* serialise through completion,
and a resume *must not* block a healthy sync or launch behind one; try-acquire is the
single primitive that gives both.

**Consequences.** The `ConflictingPendingRotation` fail-safe stays exactly where
#622 put it, now as a genuine last-resort guard rather than the common path — a
future change that reintroduced overlap would still fail closed rather than orphan an
epoch. The lock is process-local and single-device by construction; cross-device
concurrency is a different problem the signed log and the server's digest rule
already govern, and this ADR does not touch it. Alternatives considered and
rejected: a per-Workspace lock (lock-ordering hazard across the two Workspaces one
ceremony spans, for no gain); and a re-entrant lock the internal resume could
re-take (it would work, but the wrapper/core split states the "this runs already
holding the lock" contract in the type of the call rather than hiding it in a
recursion counter).

Relates to ADR-0037 (the key-wrap sealed box and the digest the server checks a
wrap set against) and builds directly on PR #622's resumable publish and its
`PendingRotationStore` fail-safe.
