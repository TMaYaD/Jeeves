# ADR-0037: KeyWraps use a hand-rolled sealed box, not `crypto_box_seal`

**Status:** Accepted (2026-07-30, issue #554)

A KeyWrap delivers a Workspace content key `K_{w,epoch}` to one Member by sealing it
to that Member's registered X25519 `kex_pk`. The obvious construction is libsodium's
`crypto_box_seal`, which exists precisely for anonymous sealing to a public key. We
defined our own instead:

```
info = "jeeves/keywrap/v1" || epk 32B || workspace_id 16B
    || epoch u32 BE || member_id 16B || kex_key_id 8B

wrap = epk 32B || nonce 24B || XChaCha20-Poly1305(
           key = HKDF-SHA256(ikm = X25519(esk, kex_pk), salt = "", info),
           nonce, aad = info, plaintext = K 32B)
```

**Why not the battle-tested one.** The protocol has two independent codecs — Dart and
Python — and both have to produce identical bytes, because that byte equality is the
whole mechanism behind `spec/sync/`'s frozen vectors. libsodium's sealed box has no
Dart implementation that runs on web, and the web build is a target `cd-app.yml`
produces. A Dart-side FFI binding would take the op-log stack off web entirely, and a
pure-Dart reimplementation of `crypto_box_seal` would be a hand-rolled construction
wearing a trusted name — strictly worse than a hand-rolled one that says so. Every
primitive we do use (X25519, HKDF-SHA256, XChaCha20-Poly1305) exists in both
runtimes, and all four were cross-checked byte-for-byte before any bytes were frozen.

**Two consequences worth stating rather than discovering.** PyNaCl ships **no HKDF**,
so `app/sync/key_wraps.py` hand-rolls RFC 5869 HKDF-SHA256 — twelve lines,
deterministic, and anchored to the RFC's own A.1 test vector rather than only to
agreement with Dart, since two wrong implementations would agree just as happily.
And `package:cryptography`'s `Hkdf` calls the salt `nonce` and defaults it to empty
while RFC 5869 says an absent salt is `HashLen` zeros; those two readings are asserted
equivalent, because if they ever diverged every wrap would be unopenable across
languages.

**The `epk` is bound into the HKDF `info`**, following HPKE's discipline that the
encapsulated key belongs in the key schedule. It costs nothing and the format freezes
for ever, so it goes in now rather than being wished for later. The rest of `info` —
`workspace_id`, `epoch`, `member_id`, `kex_key_id` — is what makes a wrap
undeliverable anywhere but its own slot: because `info` is *both* the HKDF info and
the AEAD AAD, a wrap misrouted to another member, epoch, Workspace or key fails to
authenticate rather than decrypting to garbage. An honest-but-confused server cannot
misroute one, and a hostile one gains nothing by trying.

**The trade-off accepted.** We give up a construction with a decade of review, and we
take on the obligation that this format is now ours to get right — which is why it is
pinned by golden vectors in both directions (seal to exact bytes, and unwrap back to
the key) rather than merely by a round-trip test in one language. What we buy is a
construction that runs on every platform the app ships to, and one a deterministic
generator can reproduce, which is what makes the vectors possible at all.

**The escrow wrap is a separate, simpler flavour** — one per `(Workspace, epoch)`,
symmetric under the `master_wrap_key` the recovery escrow has carried since #553, with
`"jeeves/epoch-key-escrow/v1" || workspace_id || epoch` as its AAD. It exists because
it is what makes a fresh device's bootstrap work with **no live second device**: the
passphrase yields `master_wrap_key`, which opens every historical epoch key, which
decrypts the whole history. That is the same invariant enrolment already runs on, and
preserving it is why epoch keys are escrowed rather than only ever wrapped
peer-to-peer.

**A `rotate` op carries a `keywrap_digest` over the whole wrap set**, and this is the
part that is not merely plumbing. The digest is signed into the log *before* any wrap
is uploaded, and `PUT /w/{w}/keywraps` refuses a set that does not hash to it — so the
server can neither add a wrap for a member the owner never wrapped to nor omit one and
lock an honest member out. Entries are sorted by `(member_id, kex_key_id)` so the
digest is a property of the *set* rather than of an upload order the server chooses,
and the escrow wrap is inside it so the one path with no second device to notice
cannot be substituted either. Without the commitment living in the signed log,
deciding who can read a new epoch would be entirely within a hostile operator's gift.

Superseded by nothing. A future change to the wrap layout ships under a new info
domain (`jeeves/keywrap/v2`), for the same reason certificates version by signing
domain (ADR-0028): old wraps stay openable under the old domain, and a downgrade is an
authentication failure rather than a parsing ambiguity.
