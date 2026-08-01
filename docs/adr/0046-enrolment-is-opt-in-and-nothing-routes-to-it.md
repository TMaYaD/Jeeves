# ADR-0046: Enrolment is opt-in, and no code path routes the user to it

**Status:** Accepted (#673). Constrains ADR-0034; applies ADR-0040's stance to the
session layer.

## Context

`SessionGate.needsEnrolment` pinned every location to `/enrolment` for a device that was
signed in and whose store said it was not enrolled. The reasoning was tidy: onboarding is
one decision, so take it in the router rather than in each sign-in handler, and a deep
link then cannot skip it.

It broke on a path nobody had put a device on. ADR-0041 (#606) correctly stopped an
inconclusive refresh from clearing credentials, so an offline relaunch stayed signed in
instead of falling back to signed-out — which made the gate consult the store for the
first time on that path. The author opened the app, was put in the enrolment ceremony, and
could not get back to their data: the ceremony needs the network to found or join, and
there was none. The only control on the screen was **Sign out**.

The underlying problem was the premise. The combination the trap needed — an unverified
session over a store that genuinely reports "not enrolled" — was never exercised by any
test. The arm was untested rather than merely wrong, and it shipped because **the old tests
could not produce this state**, not because nothing could: production reached it on the
first try, by the offline relaunch described above.

## Decision

**Enrolment is opt-in. No code path routes the user to it; every route to it originates in
an explicit user action.** The gate still reports enrolment — `signedInNotEnrolled` — but
that answer decides what Settings *offers*, never where the user *is*. Signing in and
signing up both land in the app whatever the store says.

The ceremony is reachable from two places, both pushed so backing out is real: the SYNC
section of Settings ("Set up sync on this device"), and the first-launch card's "Sign in
to sync", which leads to sign-in and from there to registration. The router's only
remaining move concerning the ceremony is negative — bouncing `/enrolment` back to `/inbox`
for a signed-out device (no account to enrol against) and an enrolled one (nothing left to
do, which is also how a completed ceremony hands the user back to the app). It keeps one
other redirect, unrelated to enrolment: `/register` to `/login` in SWS mode.

The alternative we rejected is routing into the ceremony from a *successful sign-in*, on
the argument that the user asked for sync. It reads as a continuation of their action, and
it closes the cliff where somebody signs in expecting sync and gets none until they find a
Settings tile. We rejected it because the failure this ADR exists for was precisely an app
deciding, on the user's behalf and with no network, that they should be somewhere else —
and because a rule with one sanctioned exception is a rule that grows more. The cliff is
paid for with discoverability in Settings instead.

## Consequences

Local-only is a first-class steady state whether or not the device is signed in, and the
app must never present it as transitional. A signed-in device that never enrols is not
broken.

Removing the redirect makes the entry points load-bearing rather than convenient: with
nothing routing the user in, an entry point that is missing or hidden does not make
enrolment awkward, it makes sync impossible. Discoverability stops being a courtesy and
becomes the mechanism, for as long as this decision stands.

Reading enrolment can fail — the store may not be readable when the question is asked — so
the guarantee the failure default has to carry is narrow and exact: **when the stack or the
enrolment store cannot be read, a signed-in device must not be routed into `/enrolment`.**
Not "goes nowhere": the read fails open to `ready`, under which the router still bounces an
already-open `/enrolment` to `/inbox`. That is a bounce *off* the ceremony, which is the
direction this decision cares about. The default is now safe rather than dangerous, and
that is the second reason the decision is worth having: under the old redirect an unreadable
store was one bad guess away from stranding a device in a ceremony it could not complete.

See `docs/ARCHITECTURE.md` for where the states are produced and read, and
`docs/TESTING.md` for the coverage that holds them.
