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

The deeper problem was the premise. Every existing `SessionUnverified` test ran without a
sync stack, so `_enrolmentGate()` could not read the store, failed open to `ready`, and
the combination "unverified session, store that genuinely says `notEnrolled`" was never
exercised anywhere. The arm was untested, not merely wrong.

## Decision

**Enrolment is opt-in. No code path routes the user to it; every route to it originates in
an explicit user action.** The gate still reports enrolment — `signedInNotEnrolled` — but
that answer decides what Settings *offers*, never where the user *is*. Signing in and
signing up both land in the app whatever the store says.

The ceremony is reachable from two places, both pushed so backing out is real: the SYNC
section of Settings ("Set up sync on this device"), and the first-launch card's "Sign in
to sync", which leads to sign-in and from there to registration. The router's only
remaining move is negative — bouncing `/enrolment` back to `/inbox` for a signed-out
device (no account to enrol against) and an enrolled one (nothing left to do, which is
also how a completed ceremony hands the user back to the app).

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

Removing the redirect makes the Settings tile load-bearing: without it, enrolment is not
opt-in but unreachable, and sync could never start. `test/screens/settings/sync_section_test.dart`
pins it for exactly that reason.

The blind spot is closed rather than merely worked around: `test/sync/offline_relaunch_session_test.dart`
now covers a signed-in, genuinely un-enrolled device over a stack that assembles for real,
online and off, and asserts both that the user reaches the app and that deliberate
navigation to the ceremony still works. `_enrolmentGate()` continues to fail open to
`ready` when the stack cannot be read, and that is now stated where it can mislead: a
`ready` in the session-layer tests means "unreadable", not "enrolled".
