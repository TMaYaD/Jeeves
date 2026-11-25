/// The arrival switch's ask for "location all the time" (issue #1092).
///
/// The switch is the one thing in Jeeves that may ask the phone for the
/// location beyond the screen it is on, so the ask is behind an explanation
/// the user has to accept first. That explanation is the prominent disclosure
/// the Play Store asks for before a phone may be asked for background
/// location.
///
/// Nothing else calls the phone for "all the time". The switch is off until
/// the phone says yes, and a phone that says no leaves the switch off.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/arrival_notification_settings.dart';
import '../providers/location_source_provider.dart';
import '../services/location_source.dart';

/// Jeeves's line for the ask — a pool, because Jeeves has more than one
/// way of saying it.
const arrivalPermissionPool = <String>[
  'To tell you when you arrive at a place you have named, sir, I must know '
      'where you are at all times, and not only while I am open. It stays on '
      'this phone.',
  'With your leave, sir: I shall ask the phone for your location always, so '
      'I may speak when you arrive. It stays on this phone.',
  'I could tell you the moment you arrive, sir, if the phone would tell me '
      'where you are at any hour. It stays on this phone.',
];

final _random = Random();

/// The line Jeeves draws for the ask.
String arrivalPermissionLine() =>
    arrivalPermissionPool[_random.nextInt(arrivalPermissionPool.length)];

/// Turns the arrival switch on for [placeId] and answers whether it is on.
///
/// The phone is asked for "all the time" only after the user has accepted the
/// explanation, and only the arrival switch ever gets here. A phone that
/// allows the location only while Jeeves is open leaves the switch off, and
/// so does a phone that refuses.
///
/// The caller's surface shows the switch, and tells the user how to allow the
/// location when the switch stays off.
Future<bool> turnOnArrivalNotification(
  BuildContext context,
  WidgetRef ref,
  String placeId,
) async {
  final source = ref.read(locationSourceProvider);

  // The web has no location prompt at all.
  if (!source.supportsPermissionPrompt) return false;

  // The caller's surface may have gone while the sheet was open.
  if (!context.mounted) return false;

  // The explanation comes first. The phone is not asked until the user has
  // said yes to it.
  final explained = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => const ArrivalPermissionSheet(),
  );
  if (explained != true) return false;

  final permission = await source.requestAllTheTime();

  // The OS's standing has changed: whoever was reading it must read it again.
  ref.invalidate(locationPermissionProvider);

  if (permission != LocationPermission.always) return false;

  await ref.read(arrivalPlaceIdsProvider.notifier).turnOn(placeId);
  return true;
}

/// The explanation the user must accept before the phone is asked.
class ArrivalPermissionSheet extends StatelessWidget {
  const ArrivalPermissionSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tell me when I arrive',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              arrivalPermissionLine(),
              key: const Key('arrival_permission_line'),
              style: const TextStyle(fontSize: 14, color: Color(0xFF374151)),
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  key: const Key('arrival_permission_not_now'),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  key: const Key('arrival_permission_continue'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
