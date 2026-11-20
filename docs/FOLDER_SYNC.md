# Op-log folder sync

Part of the sync story in [SYNC.md](SYNC.md).

A signed-out device can sync through a folder a file syncer carries, with no server (`app/lib/sync/folder/`). It is a plugin: it carries signed ops and hands them to the host untouched.

- **One writer per file.** `folder.json` names the folder; each device owns `ops/<member id>/` — a `member.json` (public key, label) and numbered `NNNNNN.log` segments it alone appends to. A segment record is a length, a v1 envelope and a 4-byte checksum (`spec/sync/folder_record_vectors.json`); a segment rolls at 1 MiB or 24 hours and is never written again.
- **Cursors.** Outbound, the host's own cursor plus a local queue of signed records waiting for the file. Inbound, one per paired device: segment, byte offset and the author chain head. A cursor moves only after the host has applied what was read.
- **Reading.** A short or checksum-failing tail is "not yet arrived": no alarm, picked up on a later scan. A bad signature or a broken chain raises the existing alarm for that author and stops reading them; a chain-valid but refused payload is quarantined and skipped. A segment shorter than the read offset raises `segment_rolled_back`, and a skipped segment raises `author_chain_gap`; both resolve when the files are whole again.
- **Pairing.** Setup reads a member's `member.json` to show its fingerprint; no operation segment is read from a device until the person has compared key fingerprints on both and paired. A member whose key later changes is refused, not trusted.
- **Signed, not encrypted.** The folder gives integrity (no forgery; alarms on a broken chain, a rollback and a gap), not confidentiality: anyone who can read the folder can read the data. A rewrite of bytes a reader has already consumed is not detected: it checks that the file is still as long as what it read, not what those bytes say. Encrypting needs a way to share a key without a server — a later `aead_v1` suite on the same wire. A syncer that stops delivering is seen only as staleness.
- **No downgrade.** A device that is signed in or enrolled never binds or attaches a folder, so a folder is never newly bound by a device that holds Workspace-key data. Turning folder sync off and enrolling later leaves the folder's existing plaintext files in place. The folder is untrusted input: member names are checked as canonical UUIDs before becoming a path, lengths are bounded before any read, and the two JSON files are parsed strictly.
- **Not built:** unpairing, resetting a device's identity in a folder, compaction, scanning while the app is closed.

**Manual Android runbook** (nothing in CI runs the storage channel): on two devices, turn folder sync on in a folder your syncer carries; confirm the files appear in `ops/`; pair each from the other after comparing fingerprints; edit on each and see both converge. Then pause the syncer on one (cellular counts as connected), edit, confirm the other has not received it, resume, and check it catches up. Confirm a restart resumes without duplicate records.

## What is asserted, and where

- `app/test/sync/folder/` — a two- and three-device journey over one real directory, one group per acceptance criterion; the refusals (enrolled device, unpaired or forged member, no secrets in the folder); the carrier source scan and the v13→v14 migration. The Android storage channel is compiled by CI and checked by the runbook above only.
