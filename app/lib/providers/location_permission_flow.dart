/// The first ask for location permission (issue #55).
///
/// Jeeves asks once, after the first Place is saved — never at launch, never
/// when a sheet opens, never when a list is drawn. "Use where I am" is the
/// one other thing that may ask: the user tapped it, so they are asking for
/// their own location.
///
/// The record of the ask is device-local (shared preferences): the permission
/// belongs to this phone, and nothing about it is synced.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/location_source.dart';

/// The device-local key that records that Jeeves has asked the OS.
const String locationPermissionAskedKey = 'location_permission_asked';

/// Jeeves's own line for the ask — a pool, because Jeeves has more than one
/// way of saying it.
const locationPermissionPool = <String>[
  'To leave Next showing only what you can do here, sir, I should like to '
      'know where you are. Only while I am open.',
  'With your leave, sir: I shall ask the phone where you are, and only for '
      'as long as I am on screen.',
  'I could name what is out of reach from here, sir, if the phone would tell '
      'me where you are.',
];

final _random = Random();

/// Whether Jeeves has already asked the OS for location on this device.
Future<bool> hasAskedForLocation() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(locationPermissionAskedKey) ?? false;
}

Future<void> _markAsked() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(locationPermissionAskedKey, true);
}

/// Asks for location permission, once, after the first Place is saved.
///
/// Returns whether the OS was asked. Nothing happens when the web has no
/// permission to ask for, when Jeeves has asked before, or when the OS has
/// already granted the location.
///
/// **Jeeves keeps its own record of the ask**, because the OS cannot keep one
/// for it: Android's location plugin answers "denied" for a phone that was
/// never asked as well as for one that refused once, so the OS's standing
/// never says "Jeeves has not asked yet".
Future<bool> askForLocationAfterFirstSave(
  BuildContext context,
  LocationSource source,
) async {
  // The web has no location prompt at all.
  if (!source.supportsPermissionPrompt) return false;
  if (await hasAskedForLocation()) return false;

  // The user has already allowed the location: there is nothing to ask for.
  final permission = await source.permission();
  if (permission.isGranted) {
    await _markAsked();
    return false;
  }

  // The caller's surface may have gone while the OS answered.
  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Location'),
      content: Text(locationPermissionPool[_random.nextInt(
        locationPermissionPool.length,
      )]),
      actions: [
        TextButton(
          key: const Key('location_permission_not_now'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('location_permission_allow'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Allow location'),
        ),
      ],
    ),
  );

  // The user has been asked, whatever they answered: the explanation does
  // not come back at the next save. The OS itself is only asked when the
  // user said yes.
  await _markAsked();
  if (accepted != true) return false;

  await source.requestWhileUsing();
  return true;
}
