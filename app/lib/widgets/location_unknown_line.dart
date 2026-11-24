/// The one calm line above the Next list when Jeeves does not know where the
/// user is (issue #55).
///
/// It says so once, in Jeeves's own words, and only when it matters: an
/// Outcome on Next carries a Place, and without a location Jeeves cannot say
/// whether it can be done here. No dialog, no snackbar, and never a line per
/// Outcome.
///
/// Where the OS has refused the location, the line carries a button that asks
/// again — or, where the OS will not ask again, opens the app's settings,
/// which is the only way left for the user to allow it.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_settings_provider.dart';
import '../providers/current_location_provider.dart';
import '../providers/gtd_lists_provider.dart';
import '../providers/location_source_provider.dart';
import '../providers/place_gate_provider.dart';
import '../services/location_source.dart';

/// Jeeves's own line for not knowing where the user is — a pool.
const locationUnknownPool = <String>[
  'I do not know where you are, sir, so I have left Next as it was.',
  'No word from the phone about your whereabouts, sir — Next keeps '
      'everything in view.',
  'Without your whereabouts, sir, I cannot say what is out of reach.',
];

final _random = Random();

/// The line above the Next list. Renders nothing when the location is known,
/// when Jeeves is still working it out, or when no Outcome on Next carries a
/// Place.
class LocationUnknownLine extends ConsumerStatefulWidget {
  const LocationUnknownLine({super.key});

  @override
  ConsumerState<LocationUnknownLine> createState() =>
      _LocationUnknownLineState();
}

class _LocationUnknownLineState extends ConsumerState<LocationUnknownLine> {
  /// The line, picked once: a line that changed its wording on every rebuild
  /// would read as if Jeeves kept changing its mind.
  late final String _line =
      locationUnknownPool[_random.nextInt(locationUnknownPool.length)];

  @override
  Widget build(BuildContext context) {
    final location = ref.watch(currentLocationProvider);
    if (location is! LocationUnknown) return const SizedBox.shrink();

    final nextIds = {
      for (final todo in ref.watch(nextProvider).value ?? const <Todo>[])
        todo.id,
    };
    final places = ref.watch(currentPlacesProvider).value ?? const {};
    final hasPlacedOutcome = places.keys.any(nextIds.contains);
    if (!hasPlacedOutcome) return const SizedBox.shrink();

    final source = ref.watch(locationSourceProvider);
    // The button is for a refused permission. With the permission granted and
    // no fix to show, allowing it again would do nothing.
    final permission = ref.watch(locationPermissionProvider);
    final mayAsk = permission.maybeWhen(
      data: (value) => !value.isGranted,
      orElse: () => false,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              _line,
              key: const Key('location_unknown_line'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
          ),
          if (source.supportsPermissionPrompt && mayAsk)
            TextButton(
              key: const Key('location_unknown_allow'),
              onPressed: _allowLocation,
              child: const Text('Allow location'),
            ),
        ],
      ),
    );
  }

  /// Asks the OS again. When the OS has refused for good it will not show its
  /// prompt again, so the app's settings page is opened instead.
  Future<void> _allowLocation() async {
    final source = ref.read(locationSourceProvider);
    final result = await source.requestWhileUsing();
    if (!mounted) return;
    // The refusal for good is only ever seen here, in the result of the ask.
    if (result == LocationPermission.deniedForever) {
      await ref.read(appSettingsOpenerProvider).openSettings();
      return;
    }
    // The permission may have been granted: let Jeeves read the location
    // again rather than wait for the next resume.
    ref.invalidate(currentLocationProvider);
    ref.invalidate(locationPermissionProvider);
  }
}
