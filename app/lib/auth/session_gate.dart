/// The one thing the router and Settings need to know about this device's
/// session.
///
/// A plain [ValueNotifier] rather than a provider because it is the router's
/// `refreshListenable`, and GoRouter is constructed once at import time with no
/// `ProviderScope` in reach. `AuthNotifier` owns every write to it (four moments:
/// session restore, sign-in/sign-up, sign-out, and a completed enrolment
/// ceremony); everything else only reads.
///
/// Four states rather than a bool because the two questions the app turns on —
/// "is there a session?" and "is this device enrolled?" — collapse into one
/// answer at every read, and each reader would otherwise have to ask the second
/// itself, from a synchronous callback with no `await` to spend.
///
/// **No state here sends the user anywhere.** Enrolment is opt-in: the gate
/// reports what is true so a surface can offer the right next step, and the
/// offer is the user's to take (issue #673).
library;

import 'package:flutter/foundation.dart';

enum SessionGate {
  /// Session restore has not answered yet. The app is fully usable while the
  /// answer is in flight, and no surface may claim anything about the account.
  checking,

  /// Nobody is signed in. The app runs local-only — a first-class steady state,
  /// not a stop on the way to somewhere. Signing in is an offer.
  signedOut,

  /// Signed in, and this device's store says it is not enrolled (or was left
  /// half-founded). The app runs exactly as it does for any other state; what
  /// this changes is what Settings offers — the enrolment ceremony, which is the
  /// only way sync ever starts.
  signedInNotEnrolled,

  /// Signed in and enrolled: the app, and sync running behind it.
  ready,
}

/// The live gate the production router refreshes on. Tests build their own and
/// pass it to `buildAppRouterRedirect`.
final ValueNotifier<SessionGate> sessionGateNotifier =
    ValueNotifier<SessionGate>(SessionGate.checking);
