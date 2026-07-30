/// The one thing the router needs to know about this device's session.
///
/// A plain [ValueNotifier] rather than a provider because it is the router's
/// `refreshListenable`, and GoRouter is constructed once at import time with no
/// `ProviderScope` in reach. `AuthNotifier` owns every write to it (four moments:
/// session restore, sign-in/sign-up, sign-out, and a completed enrolment
/// ceremony); the router only reads.
///
/// Four states rather than a bool because the two questions the flow turns on —
/// "is there a session?" and "is this device enrolled?" — collapse into one
/// answer at every decision point, and a router that could only ask the first
/// would have to ask the second itself, from a redirect callback with no `await`
/// to spend.
library;

import 'package:flutter/foundation.dart';

enum SessionGate {
  /// Session restore has not answered yet. **Redirects nothing**: a cold start
  /// must not flash the onboarding screen at an enrolled device, and the app is
  /// fully usable while the answer is in flight.
  checking,

  /// Nobody is signed in. The app runs local-only and every route stays
  /// reachable — signing in is an offer, never a wall.
  signedOut,

  /// Signed in, and this device's store says it is not enrolled (or was left
  /// half-founded). Onboarding is unfinished, so `/enrolment` is the only
  /// location; **Sign out** is the way back.
  needsEnrolment,

  /// Signed in and enrolled: the app, and sync running behind it.
  ready,
}

/// The live gate the production router refreshes on. Tests build their own and
/// pass it to `buildAppRouterRedirect`.
final ValueNotifier<SessionGate> sessionGateNotifier =
    ValueNotifier<SessionGate>(SessionGate.checking);
