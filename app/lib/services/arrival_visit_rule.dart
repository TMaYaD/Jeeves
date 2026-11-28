/// When an arrival starts a new visit, and whether that arrival may notify
/// the user (issue #1092).
///
/// A **visit** is one stay at a Place. The user walks out of the hardware
/// store to fetch a screw and comes straight back: that is one visit, and the
/// store may say nothing more about it. Only an absence of at least
/// [arrivalVisitGap] ends the visit, so the next arrival is a new one and may
/// tell the user again.
///
/// The rule is pure: it takes what the phone remembers about a Place and
/// returns what it should remember next. It knows nothing about the database,
/// the clock or the notification, so it can be reasoned about on its own.
///
/// The rule never opens the store and never asks for a place: the caller
/// passes in whether something is due there.
library;

/// How long the user has to be away before the next arrival is a new visit.
const Duration arrivalVisitGap = Duration(minutes: 30);

/// What the phone remembers about one Place's visits.
///
/// [inside] says whether the user is in the Place now. [lastExitAtUtc] is when
/// the user last left it — null when there is no usable exit time. And
/// [notifiedThisVisit] says whether the user has already been told about this
/// visit.
typedef PlaceVisit = ({
  bool inside,
  DateTime? lastExitAtUtc,
  bool notifiedThisVisit,
});

/// Applies an arrival at a Place and says whether the user is to be told.
///
/// Arriving while already inside changes nothing and tells nothing: the user
/// is still in the same visit, and that visit has had its say.
///
/// Otherwise the arrival either continues the last visit or starts a new one.
/// A new visit starts when there is no record of a visit, when the record has
/// no exit time to measure the absence from, or when the absence is at least
/// [arrivalVisitGap] long. A new visit has not told the user anything yet.
///
/// The user is told when something is due at the Place and this visit has not
/// told them yet — and telling them marks the visit as told, so a second
/// arrival in the same visit stays quiet.
({PlaceVisit visit, bool notify}) onEnter(
  PlaceVisit? visit, {
  required DateTime nowUtc,
  required bool somethingDue,
}) {
  if (visit != null && visit.inside) {
    return (visit: visit, notify: false);
  }

  final lastExitAtUtc = visit?.lastExitAtUtc;
  final startsNewVisit = visit == null ||
      lastExitAtUtc == null ||
      nowUtc.difference(lastExitAtUtc) >= arrivalVisitGap;
  final toldThisVisit = startsNewVisit ? false : visit.notifiedThisVisit;

  final notify = somethingDue && !toldThisVisit;
  return (
    visit: (
      inside: true,
      // A visit under way has no exit behind it yet.
      lastExitAtUtc: null,
      notifiedThisVisit: notify || toldThisVisit,
    ),
    notify: notify,
  );
}

/// Applies a departure from a Place.
///
/// The visit is over but not forgotten: the visit keeps whether the user has
/// been told, so an arrival that follows shortly afterwards can tell them
/// what came up in the meantime.
PlaceVisit onExit(
  PlaceVisit? visit, {
  required DateTime nowUtc,
}) =>
    (
      inside: false,
      lastExitAtUtc: nowUtc,
      notifiedThisVisit: visit?.notifiedThisVisit ?? false,
    );
