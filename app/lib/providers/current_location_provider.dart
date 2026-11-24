/// Where the user is, as far as Jeeves knows (issue #55).
///
/// The location is held in memory only: it is never written to the store, to
/// shared preferences or to a file.
///
/// **Reads happen while Jeeves is on screen and stop when it is not.** On
/// resume Jeeves asks for a fresh fix, and falls back to the OS's last known
/// position however old that is. A background code path never reads a
/// location for the Next list.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/location_source.dart';
import 'location_source_provider.dart';

/// How long a fresh fix may take before the OS's last known position is used
/// instead.
const Duration locationFreshFixTimeout = Duration(seconds: 10);

/// What Jeeves knows about where the user is.
sealed class CurrentLocation {
  const CurrentLocation();
}

/// Jeeves is still working it out: the first read has not answered yet.
final class LocationPending extends CurrentLocation {
  const LocationPending();
}

/// Jeeves does not know where the user is — the web, a refused permission, or
/// neither a fresh fix nor a last known position.
final class LocationUnknown extends CurrentLocation {
  const LocationUnknown();
}

/// Jeeves knows where the user is.
final class LocationKnown extends CurrentLocation {
  const LocationKnown(this.point);

  final GeoPoint point;
}

/// The user's location, right now.
final currentLocationProvider =
    NotifierProvider<CurrentLocationNotifier, CurrentLocation>(
        CurrentLocationNotifier.new);

class CurrentLocationNotifier extends Notifier<CurrentLocation>
    with WidgetsBindingObserver {
  StreamSubscription<GeoPoint>? _subscription;
  bool _disposed = false;

  @override
  CurrentLocation build() {
    // A test that never builds a widget has no binding to watch. The
    // location is then read once, and nothing hears of a resume.
    final binding = _bindingOrNull();
    if (binding != null) {
      binding.addObserver(this);
      ref.onDispose(() => binding.removeObserver(this));
    }
    ref.onDispose(() {
      _disposed = true;
      _subscription?.cancel();
    });
    _startReading();
    return const LocationPending();
  }

  /// The app's binding, when there is one.
  static WidgetsBinding? _bindingOrNull() {
    try {
      return WidgetsBinding.instance;
    } on FlutterError {
      return null;
    }
  }

  /// Reads the location: a fresh fix first, the OS's last known position
  /// when the fix does not arrive, and nothing when neither is there.
  ///
  /// The position stream is opened only where the OS allows a read: without
  /// the permission there is nothing to listen to, and asking for it would
  /// only raise an error where there is no answer to give.
  Future<void> _startReading() async {
    final source = ref.read(locationSourceProvider);
    final point = await _readPoint(source);
    if (_disposed) return;
    state = point == null ? const LocationUnknown() : LocationKnown(point);
    await _subscription?.cancel();
    if (_disposed) return;
    if (!await _mayListen(source)) return;
    if (_disposed) return;
    _subscription = source.whileOpen().listen(
      (position) {
        if (_disposed) return;
        state = LocationKnown(position);
      },
      onError: (Object _) {
        // A stream that fails leaves Jeeves with the last position it had.
      },
    );
  }

  /// Whether the OS lets Jeeves listen for positions.
  Future<bool> _mayListen(LocationSource source) async {
    try {
      final permission = await source.permission();
      return permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
    } on Object {
      return false;
    }
  }

  Future<GeoPoint?> _readPoint(LocationSource source) async {
    try {
      final fresh = await source.freshFix(timeout: locationFreshFixTimeout);
      if (fresh != null) return fresh;
    } on Object {
      // A fix that fails is no fix.
    }
    try {
      return await source.lastKnown();
    } on Object {
      // No last known position either.
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startReading();
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // Nothing is read while Jeeves is off screen.
      _subscription?.cancel();
      _subscription = null;
    }
  }
}
