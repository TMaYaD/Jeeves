# ADR-0039: A rotation persists its wrap set before the flush, and resumes by idempotent re-PUT

**Status:** Accepted (2026-07-31, issue #617)

A key rotation publishes an epoch's wrap set in two steps that are not atomic.
`EnrolmentService._rotateOne` flushes the signed `rotate` — after which the server
has materialised it and every device's epoch floor rises to `toEpoch` on its next
pull — and only then PUTs the wraps and remembers the key. A crash, a dropped
connection, or the user backgrounding the app between those two steps used to strand
the epoch **permanently**: nobody held `K_{w,N+1}`, and it could not be
reconstructed. The `rotate` committed `keywrap_digest` over a wrap set built from
entropy held only in the transient `EpochKeySet` (a fresh epoch key, ephemeral
scalars, wrap nonces); a second `prepare` draws fresh entropy, so its digest can
never match the one the log already committed to, and `PUT /w/{w}/keywraps` correctly
refuses it as `keywrap_digest_mismatch`. Both sides then degrade silently — the
rotating device authors `plaintext_v1` at a keyed epoch (its key lookup returns
null), and peers quarantine content on `missing_epoch_key` with nothing to heal them.

**The decision: keep the prepared wrap set durable, written before the flush, and
resume the PUT.** The `EpochKeySet` — member wraps, escrow wrap, digest, and
`workspaceKey` — is persisted to a `PendingWrapSetStore` keyed by `(workspaceId,
toEpoch)` immediately before `flushOutbox()`, and removed once `publish` has both
uploaded the set and remembered the key. A resume step (`SyncClient.resumePendingWrapSets`)
re-PUTs the byte-identical set from three triggers that cover every path a device
takes — the next ceremony, the pull tail, and launch (the last two are the same hook:
every launch syncs, every sync pulls). The record's *presence* is the retry
condition, mirroring the outbox and the two-slot escrow write: an unmaterialised
`rotate` or an unreachable server simply leaves it for the next trigger, and a record
whose epoch is already held (a crash after the key was remembered but before the
record was dropped) is discarded rather than retried for ever.

**Why the keychain tier, never the sync database.** The record carries `workspaceKey`
in the clear — it is exactly the sensitivity of the epoch-key map itself — so it sits
on the same platform-keychain posture as `WorkspaceKeyStore` (ADR-0037's escrow-wrap
reasoning applies unchanged). Putting it in the store that also holds the ciphertext
would make the encryption decorative on a device whose sync file was copied, which is
review F22's explicitly unclaimed at-rest gap.

**The trade-off accepted.** We take on a second persisted-secret store and a
keychain read on every pull, in exchange for a ceremony that survives a crash with no
operator action and no UI. Two alternatives were rejected. A dedicated server "resume
rotation" endpoint would change `PUT /w/{w}/keywraps`' contract, which #617 keeps out
of scope precisely because the server already treats a byte-identical replay as a 200
acknowledgement (the `IntegrityError` fix landed in #590) — an idempotent re-PUT needs
no new surface. And caching `master_wrap_key` on the device to re-mint the epoch
unattended would move escrow material out from behind the passphrase for a
convenience, the wrong side of the trade the scheduled-rotation prompt already makes.
The wrap format, the digest construction, and the PUT contract are all unchanged;
this is durability around the existing ceremony, not a change to it.
