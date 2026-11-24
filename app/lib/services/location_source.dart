/// The port through which Jeeves reads where the user is (issue #55).
///
/// The location lives in memory only: it is never written to the store, to
/// shared preferences or to a file. Everything that reads it goes through this
/// port, so a journey can stand a recording fake in for the platform — the
/// real implementation asks the OS, the fake answers what the test says and
/// remembers every call.
///
/// **A read never asks for permission.** Only [requestWhileUsing] asks, and
/// only an explicit tap by the user may call it.
library;

/// A point on the globe, in degrees.
typedef GeoPoint = ({double latitudeDegrees, double longitudeDegrees});

/// What the OS says about location permission.
enum LocationPermission {
  /// The OS has not been asked yet.
  notAsked,

  /// Refused. The OS may still show its prompt.
  denied,

  /// Refused for good: the OS will not show its prompt again.
  deniedForever,

  /// Allowed while the app is on screen.
  whileInUse,

  /// Allowed always.
  always;

  /// Whether the OS may still be asked.
  bool get canAskAgain => this == notAsked || this == denied;
}

/// Where Jeeves reads the user's location from.
abstract class LocationSource {
  /// Whether this platform has a location prompt at all. False on the web,
  /// where Jeeves never reads a location.
  bool get supportsPermissionPrompt;

  /// What the OS currently says. Never asks.
  Future<LocationPermission> permission();

  /// Asks the OS for "while using" permission and answers what it granted.
  /// Only an explicit tap by the user may call this.
  Future<LocationPermission> requestWhileUsing();

  /// The OS's last known position, however old. Null when there is none.
  /// Never asks for permission.
  Future<GeoPoint?> lastKnown();

  /// A fresh position, or null when it does not arrive within [timeout].
  /// Never asks for permission.
  Future<GeoPoint?> freshFix({required Duration timeout});

  /// Positions while Jeeves is on screen. The stream is ended when the app is
  /// paused.
  Stream<GeoPoint> whileOpen();
}

/// The port through which Jeeves turns a typed address into a point.
///
/// The platform geocoder sends the address the user typed to Google, which is
/// why the address is a personal-data touch (issue #55).
abstract class AddressGeocoder {
  /// The point for [address], or null when the geocoder does not know it or
  /// does not answer.
  Future<GeoPoint?> pointForAddress(String address);
}
