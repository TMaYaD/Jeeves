# ADR-0031: Workspace genesis embeds the founding registration

## Status

Accepted.

## Context

ADR-0028 put the control plane in the log: membership is a Root-signed
`member_register` control op, and Root never authors an envelope. #549 adds
Workspace existence as a signed fact — a `workspace_genesis` control op that must
be the Workspace's *first* control op, so that an all-zero `prev_control_hash`
means "nothing preceded this" and nothing else.

Those three rules collide. Genesis must come first; a registering control op is
its author's op 1; Root authors nothing. So the genesis envelope is authored by
the founding Device *before any `member_register` for it exists* — and a verifier
therefore has no way to learn the author's key before it has verified the
envelope it is holding. Three-op alternatives were considered (genesis, then
register, then grant) and all of them founder on the same point: the genesis
envelope is unverifiable without a key, and the only place that key can come from
is the genesis certificate itself. At which point the registration is already
embedded, and the extra op buys nothing.

## Decision

**The genesis certificate carries the founding Member's registration, and genesis
*is* that member's registration.** The founding device authors no separate
`member_register`. #548's rule generalises: *an author's first op must be the
control op that registers it — a `member_register`, or the `workspace_genesis`
that embeds one.* The certificate also carries `root_pk`, so every later verifier
has a log-internal cross-check against the Root it pinned.

Three rules follow from it and are recorded here because they are equally hard to
reverse.

**An all-zero `prev_control_hash` is genesis-only, both ways.** A
`member_register`, grant or revoke carrying one is refused even by a receiver
whose control state is empty — which is what makes a truncated history *always*
detectable, closing the residual #548 documented. A genesis carrying anything
else is refused too, because it is by definition first. The corollary: any
pre-genesis dev-era log, one that opens with a zero-link `member_register`, is
permanently unadoptable. That is acceptable because PowerSync is still the
production sync path and the op-log store ships empty at the #553 cutover, so no
such log exists outside development debris.

**Genesis authorship is log-state-conditioned, not device-ordinal-conditioned.**
*Any* device holding Root authors the genesis for a Workspace whose control log it
observed empty. A first-device rule would leave an unrecoverable window: a User
has two implicit Workspaces, the ceremony writes both escrow slots and then founds
both, and a crash between the two genesis posts would leave the second Workspace
genesis-less for ever — every later device would take the "Nth device" path into
it and be fork-refused. Conditioning on the log closes that: the next enrolling
device observes the empty log and founds it. The price is that the ceremony must
*pull before it claims*, which is why the server admits a member GET with no
Grant at all, and why a pre-genesis GET returns an empty page rather than an
error.

**The owner authority ceiling is symmetric: an `owner` Grant is Root-mint and
Root-revoke.** Devices do become owners — via the Root-signed grant every
enrolment authors — but *elevation* to owner always takes the passphrase, exactly
like demotion from it. The symmetry is the point. An owner-mints-owner rule would
let a compromised device create an attacker-owner cheaply while removing one still
cost Root, and that asymmetry favours the attacker: they gain authority faster
than the User can take it away. The corollary is deliberate and its UX cost is
real — revoking a Device requires the passphrase — and it is relaxable later at
that cost only, never for free. The mint half is a pure document invariant and is
enforced at decode wherever the bytes are held; the revoke half needs the target
Grant's role, which is receiver state, so it lives in the route and in the
client's authorization stage.

## Consequences

Genesis is protocol identity, so reversing any of this after the vectors froze is
a protocol change: one op does two jobs, and a reader who did not know why would
reasonably try to split it. #554's rotation inherits the frozen `jeeves/grant/v1`
certificate shape — rotation must not touch it, that being the point of the
Grant/KeyWrap split. #553 inherits the larger UX commitment the owner ceiling
implies. And #555 inherits the rule that control ops are never compacted: the
authority record cannot be folded away, or the evidence that a Grant ever existed
goes with it.
