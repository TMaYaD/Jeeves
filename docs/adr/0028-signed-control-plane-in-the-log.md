# ADR-0028: The control plane lives in the signed log, chained to a passphrase-escrowed Root

**Status:** Accepted
**Date:** 2026-07-27
**Context:** ADR-0026. Security review finding F1–F3 (`docs/proposals/minimal-sync-server-security-review.md`), adopted in full.

## Decision

**Membership and key facts are signed control ops in the op log, not server table state.** Grants, revocations, rotations, and member registrations are ops of `op_class=control`, signed and chained back to a per-User **Root** — a random Ed25519 keypair generated at account creation and escrowed under the passphrase. The server's grants/members tables are a materialised index it uses for its own content-blind authz; they are authoritative for nobody. Clients pin the Root public key on first successful escrow unwrap (trust-on-first-use against the *passphrase*, not the server) and refuse any Member not chained to it. Per-author chains in every op header (`author_seq`, `prev_author_hash`) plus a client-persisted monotone `epoch_floor` make the server's remaining moves — truncation, rollback, and above all *suppressing a rotation by silence* — detectable rather than invisible.

The alternative this rejects is the one we initially recorded: server-managed membership with signature "columns reserved now, enforcement later." The review's F1 showed that deferral is void, not merely risky — per-op signatures are only as strong as the registry the verifier resolves authors against, and if that registry is server-supplied, a malicious server registers its own member key and signs whatever it likes. Nor can enforcement be retrofitted: ops signed by an unchained member during the deferral window can never be retroactively attributed — the same argument that put per-op signatures in v1 puts the signed control plane there too. A signed data plane over an unsigned control plane is decoration.

Root also resolves the constraint that shaped everything: a single-device user must enrol a new device with only a passphrase, no second device online. The passphrase therefore stops being merely a key-wrapper and becomes the gate to a *signing authority* — an enrolling device unwraps the escrow with it, obtains the random Root key, holds Root for the duration, and signs its own registration with Root. The passphrase itself never signs.

## Consequences

Control ops are never compacted — they are tiny, and they are the only thing that lets a fresh device reconstruct who was allowed to say what. Root is random, never passphrase-derived, so a passphrase change is a re-wrap, not a new identity. The escrow (`root_sk || master_wrap_key`) is the E2EE ceiling against a stolen-ciphertext adversary, hence the diceware-default passphrase policy recorded in the proposal.
