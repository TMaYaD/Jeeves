/// The recording stand-ins for the OS's location (issues #55 and #1092).
///
/// [FakeLocationSource] answers what the test says and remembers every call,
/// so a journey can prove that Jeeves reads the location only while it is on
/// screen, that a fresh fix falls back to the last known position, and that
/// the permission is asked once and only on the user's ask.
///
/// **The fake answers what the phone answers.** Android's location plugin
/// says "denied" for a phone that was never asked as well as for one that
/// refused once, and it never says "not asked" or "denied for good" — only
/// the result of a request can say the last. The fake's default is therefore
/// "denied", and a test that wants the refusal for good sets
/// [requestResult] to it.
///
/// The arrival switch is the only thing that may ask for "location all the
/// time", so [allTheTimeRequests] counts that ask on its own: a journey that
/// never touches the switch expects it to stay at zero.
///
/// [FakeAddressGeocoder] stands in for the platform geocoder, which is what
/// turns a typed address into a point.
library;

import 'dart:async';

import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/services/app_settings_opener.dart';
import 'package:jeeves/services/location_source.dart';

/// The OS's location, stood in for.
class FakeLocationSource implements LocationSource {
  FakeLocationSource();

  /// What `permission()` answers.
  ///
  /// "Denied" by default: the plugin cannot tell a phone that was never
  /// asked from one that refused once, and it never says "not asked".
  LocationPermission permissionState = LocationPermission.denied;

  /// What `requestWhileUsing()` answers.
  ///
  /// Set it to [LocationPermission.deniedForever] to model a refusal for
  /// good: the OS shows no prompt, and the app's settings page is the only
  /// way left to allow the location. That refusal is only ever seen in the
  /// result of the ask — the standing check answers "denied", as the plugin
  /// does.
  LocationPermission requestResult = LocationPermission.whileInUse;

  /// The point a fresh fix returns. Null stands for a fix that does not
  /// arrive.
  GeoPoint? freshPoint;

  /// A gate a fresh fix waits on, when the test says when the OS answers.
  ///
  /// Null means the fix answers at once. A gate lets a journey pause Jeeves
  /// while the fix is still on its way, which is where a read can go wrong.
  Completer<GeoPoint?>? freshFixGate;

  /// A gate the permission request waits on, when the test says when the OS
  /// answers.
  ///
  /// The OS's own prompt takes Jeeves off screen for a moment. A gate lets a
  /// journey put the app off screen while the ask is still on its way, which
  /// is where a read can start too late.
  Completer<void>? requestGate;

  /// What `requestAllTheTime()` answers.
  ///
  /// The phone's answer to "allow this app to use your location all the
  /// time". It is "always" by default: a phone that is asked and says yes.
  /// Set it to [LocationPermission.whileInUse] for a phone that allows the
  /// location only while Jeeves is open, or to
  /// [LocationPermission.deniedForever] for one that will not ask again.
  LocationPermission allTheTimeResult = LocationPermission.always;

  /// The point the OS's last known position returns. Null stands for a phone
  /// that has never had a fix.
  GeoPoint? lastKnownPoint;

  /// Whether this platform has a permission prompt at all. The web has none.
  bool promptSupported = true;

  /// Every call the fake received, in order.
  final calls = <String>[];

  /// How many times Jeeves asked the OS for permission.
  int permissionRequests = 0;

  /// How many times Jeeves asked the OS for "location all the time".
  ///
  /// The arrival switch is the only thing that may ask for it, so a journey
  /// that never touches the switch expects this to stay at zero.
  int allTheTimeRequests = 0;

  final StreamController<GeoPoint> _positions =
      StreamController<GeoPoint>.broadcast();

  @override
  bool get supportsPermissionPrompt => promptSupported;

  @override
  Future<LocationPermission> permission() async {
    calls.add('permission');
    return permissionState;
  }

  @override
  Future<LocationPermission> requestWhileUsing() async {
    calls.add('requestWhileUsing');
    permissionRequests++;
    final gate = requestGate;
    if (gate != null) await gate.future;
    // The refusal for good is only ever seen in the result of the ask. The
    // standing check answers "denied", as the plugin does: it cannot say the
    // OS will not ask again.
    permissionState = requestResult == LocationPermission.deniedForever
        ? LocationPermission.denied
        : requestResult;
    return requestResult;
  }

  /// The phone's answer to "allow this app to use your location all the
  /// time".
  ///
  /// The phone grants it or it does not; it never asks a second question.
  /// A granted answer becomes the standing, so a later standing check sees
  /// it, and a refusal for good leaves the standing at "denied" — as the
  /// plugin does.
  @override
  Future<LocationPermission> requestAllTheTime() async {
    calls.add('requestAllTheTime');
    allTheTimeRequests++;
    final gate = requestGate;
    if (gate != null) await gate.future;
    permissionState = allTheTimeResult == LocationPermission.deniedForever
        ? LocationPermission.denied
        : allTheTimeResult;
    return allTheTimeResult;
  }

  @override
  Future<GeoPoint?> lastKnown() async {
    calls.add('lastKnown');
    return lastKnownPoint;
  }

  @override
  Future<GeoPoint?> freshFix({required Duration timeout}) async {
    calls.add('freshFix');
    final gate = freshFixGate;
    if (gate != null) return gate.future;
    return freshPoint;
  }

  @override
  Stream<GeoPoint> whileOpen() {
    calls.add('whileOpen');
    return _positions.stream;
  }

  /// Moves the user to [point] while Jeeves is on screen.
  void moveTo(GeoPoint point) => _positions.add(point);

  /// How many times the fake was asked for a read of any kind.
  int get readCalls =>
      calls.where((call) => call == 'freshFix' || call == 'lastKnown').length;

  Future<void> dispose() => _positions.close();
}

/// The platform geocoder, stood in for.
class FakeAddressGeocoder implements AddressGeocoder {
  FakeAddressGeocoder({Map<String, GeoPoint>? points, this.supportsLookup = true})
      : points = Map<String, GeoPoint>.from(points ?? const {});

  /// The point for each address, keyed by the trimmed, lower-cased address.
  final Map<String, GeoPoint> points;

  /// Whether this platform can look an address up at all. The web cannot.
  final bool supportsLookup;

  /// Every address the geocoder was asked about, in order.
  final calls = <String>[];

  /// A gate the lookup waits on, when the test says when the geocoder
  /// answers.
  ///
  /// A platform geocoder can take a moment. A gate lets a journey put a
  /// choice of the user's own in front of it.
  Completer<void>? lookupGate;

  @override
  bool get supportsAddressLookup => supportsLookup;

  @override
  Future<GeoPoint?> pointForAddress(String address) async {
    calls.add(address);
    final gate = lookupGate;
    if (gate != null) await gate.future;
    return points[address.trim().toLowerCase()];
  }
}

/// The app's own settings page, stood in for.
class FakeAppSettingsOpener implements AppSettingsOpener {
  FakeAppSettingsOpener({this.canOpen = true});

  /// Whether this device has a settings page Jeeves can open.
  final bool canOpen;

  /// Every time Jeeves opened the settings page.
  int opens = 0;

  @override
  bool get canOpenSettings => canOpen;

  @override
  Future<bool> openSettings() async {
    opens++;
    return canOpen;
  }
}

/// A location that never moves: the stand-in for a phone that has already
/// answered, and for a phone that never will.
class FixedLocationNotifier extends CurrentLocationNotifier {
  FixedLocationNotifier(this.fixedLocation);

  final CurrentLocation fixedLocation;

  @override
  CurrentLocation build() => fixedLocation;
}
