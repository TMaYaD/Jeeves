# 0041 — Only a corroborated 401 may clear a session

A silent refresh at cold start can fail for many reasons, and the client used to
collapse all of them into one nullable token: a dead socket, a timeout, a 502 from
a reverse proxy, a captive portal's login page, a malformed body, and the backend
authoritatively rejecting the refresh token all produced the same `null`, which the
client answered by deleting both stored keys and resetting the account id to the
`'local'` placeholder. That is not a spurious sign-out prompt. The account id is
what the whole sync spine hangs off — the `uuid5` Workspace ids, the escrow slot,
the Grants — so `'local'` also refuses the sync stack and settles the capture seam
**silent**, and on a device whose initial-upload marker is already set (ADR-0034)
the marker-gated walk that would re-carry those rows never runs again. An offline
relaunch therefore destroyed an enrolled device's enrolment *and* dropped every
write of the session, permanently, caused by nothing but the network being down
(#606). This is the same reasoning as ADR-0036 one layer up: the decision that
disposes of a session's writes must not be derived from a network answer.

**Credentials may be destroyed only by a `401` from `POST /session/refresh` that
also carries proof it came from the Jeeves backend, or by nothing being stored to
refresh. Every other outcome is inconclusive, and an inconclusive answer must never
cost the user their enrolment.** The rule is stated as an inversion on purpose. The
alternative — enumerate the transport failures that mean "offline" — fails open in
the wrong direction, because a 5xx, a captive portal answering 200 with a login
page, a parse error off an empty body, or a transport error class a future HTTP
client version adds would all fall through to "signed out". Naming the *one*
authoritative case makes offline the default-safe path, which is the standing
stance that the app's behaviour does not depend on a reachable server. The refresh
token is opaque — the server persists only its hash — so a client cannot determine
locally whether it would be accepted; offline the only honest answer is "I don't
know", and #606 was what happened when "I don't know" was coded as "no".

**A bare status code is not enough**, because the door declared authoritative is
reachable by whatever box answers the request — and a captive portal, hotel gateway
or authenticating proxy answers 401 *precisely* in the offline conditions where
losing an enrolment is most expensive. So the 401 is corroborated against two
signals the backend emits, and **either** is sufficient. The **primary is the
body**: a JSON object carrying a non-empty string `detail`. The **secondary is a
`WWW-Authenticate` header containing `Bearer`**. Requiring both, or making the
header primary, would have been wrong in a way no test in the app's own suite could
catch: the backend's CORS configuration exposes no response headers, which is the
framework default, so on the Flutter web build the browser hides that header from
the HTTP client entirely and every genuine 401 would have classified as
inconclusive — a platform-specific failure to sign out revoked devices, on web
only. The body is CORS-safe; the header is the second door for an absent or
unparseable one. `detail` is matched on **shape, never text**, so a copy edit on
the backend cannot silently flip every client to never-signing-out. Because the
client now depends on a response shape rather than a status code alone, that shape
is a two-sided contract, pinned by a test on each side.

The trade this accepts is holding a credential of unknown validity until a
reachable server settles it, and it is bounded and self-healing where the failure it
removes was unbounded and permanent. The device keeps the expired access token on
its HTTP client, so the first request after the network returns 401s into the retry
interceptor. Even in the worst case — the refresh token has genuinely expired
server-side by the time the device reconnects, and the user signs in again as the
same user — the queued envelopes survive: the outbox is keyed by Workspace id and a
Workspace id is `uuid5` of the account id, so they are still addressed to the same
log and still flush. Clearing early is the only branch that loses data. An
**explicit** sign-out is untouched by all of this: it is a user decision, it clears
both keys with no network, and it is tested as the guard against over-correcting.

The account id recovered from an expired access token carries **no authority**, and
a future reader must not infer otherwise. Reading it is what lets an inconclusive
relaunch stay signed in, and tolerating the expiry lowers no security bar, because
the client **does not verify the token signature at all** today — with or without
that tolerance — so there was no bar being enforced to relax. The tolerance
relaxes only the expiry check; a missing subject or an undecodable payload still
yields nothing. The id merely *selects local partitions*: the `uuid5` Workspace ids
and the escrow slot. No local read filters on it, and every real authority rests on
the server-checked bearer or member credential (ADR-0028's signed control plane,
and the member credential's proof-of-possession).

One residual is deferred by decision rather than oversight. A **torn secure store**
— a refresh token present with the access token absent or unparseable, and the
server unreachable — leaves no account id to stay signed in as, so it still clears.
It is narrow, because the client always writes both keys together and deletes both
together, and it is pinned by a test so a change to it is deliberate; recovering the
id from the pinned enrolment identity instead is #639. Separately, a refresh
rejected **mid-session** still only propagates the 401 to its caller, so the device
learns it is signed out at the next relaunch (#640) — opposite polarity to this bug,
with the seam bound and the outbox queuing throughout, so nothing is lost.

See also ADR-0034 (sync starts at enrolment, and the marker that makes a dropped
write permanent) and ADR-0036 (the capture seam's tri-state decision).
