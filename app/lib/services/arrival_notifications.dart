/// The arrival notification: told once per visit, with Jeeves closed (issue
/// #1092).
///
/// [handleArrivalEvent] is what the OS's geofence event comes to. It reads the
/// snapshot and the visit record the foreground app left on the device, applies
/// the visit rule, writes the visit record back and — when the rule says so —
/// tells the user through a [ArrivalNotificationSink].
///
/// It runs in a headless engine with no Riverpod container, and the arrival
/// path may not open the store, so it imports neither.
library;

import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'arrival_snapshot.dart';
import 'arrival_visit_rule.dart';
import 'geofence_registrar.dart' show arrivalGeofenceIdPrefix;
import 'notification_ids.dart';

/// The Android channel the arrival notifications go to.
const String arrivalNotificationChannelId = 'arrivals';

/// What the user sees of the channel in the phone's settings.
const String arrivalNotificationChannelName = 'Arrivals';

/// What the user sees of the channel in the phone's settings.
const String arrivalNotificationChannelDescription =
    'When you arrive at a Place you chose';

/// The prefix of an arrival notification's payload.
const String arrivalNotificationPayloadPrefix = 'arrival:';

/// Jeeves's lead-in to what is due. `{count}` is the number of Outcomes with
/// its noun ("Two Outcomes"), and `{await}` is the verb that agrees with it.
const arrivalNotificationPool = <String>[
  '{count} {await} you here, sir:',
  'A word, sir. {count} {await} you at this very spot:',
  'Welcome, sir. {count} {await} your attention here:',
];

/// Where an arrival notification goes to be shown.
///
/// A port, so a journey can see what the user would be told without a phone.
abstract class ArrivalNotificationSink {
  /// Shows a notification with [id], replacing any shown with the same id.
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  });
}

/// The notification's id: stable per Place, so a second arrival at the same
/// Place replaces the first instead of stacking beside it.
int arrivalNotificationId(String placeId) =>
    // The plugin takes a signed 32-bit id; the hash is unsigned.
    fnv1a32('arrival:$placeId').toSigned(32);

/// The payload a body tap routes by.
String arrivalNotificationPayload(String placeId) =>
    '$arrivalNotificationPayloadPrefix$placeId';

/// The Place a payload names, or null when it is not an arrival's.
String? arrivalPlaceIdFromPayload(String? payload) {
  if (payload == null || !payload.startsWith(arrivalNotificationPayloadPrefix)) {
    return null;
  }
  final placeId = payload.substring(arrivalNotificationPayloadPrefix.length);
  return placeId.isEmpty ? null : placeId;
}

/// The route a tap on an arrival notification opens: the place page, at that
/// Place.
String arrivalPlaceRoute(String placeId) =>
    '/places?place=${Uri.encodeQueryComponent(placeId)}';

const _countNames = <int, String>{
  1: 'One',
  2: 'Two',
  3: 'Three',
  4: 'Four',
  5: 'Five',
  6: 'Six',
  7: 'Seven',
  8: 'Eight',
  9: 'Nine',
};

/// The notification's body: a line from [arrivalNotificationPool], the count,
/// and the titles the snapshot carries — "Two Outcomes await you here, sir:
/// Buy screws, Return the drill."
///
/// When more are due than the titles name, the rest are counted: "…, and 2
/// more."
String arrivalNotificationBody({
  required int dueCount,
  required List<String> dueTitles,
  Random? random,
}) {
  final line =
      arrivalNotificationPool[(random ?? Random()).nextInt(arrivalNotificationPool.length)];
  final countName = _countNames[dueCount] ?? '$dueCount';
  final countPhrase = dueCount == 1 ? '$countName Outcome' : '$countName Outcomes';
  final lead = line
      .replaceAll('{count}', countPhrase)
      .replaceAll('{await}', dueCount == 1 ? 'awaits' : 'await');

  final unnamed = dueCount - dueTitles.length;
  final titles = dueTitles.join(', ');
  if (titles.isEmpty) return lead.replaceFirst(RegExp(r':$'), '.');
  return unnamed > 0 ? '$lead $titles, and $unnamed more.' : '$lead $titles.';
}

/// Applies a geofence event for the Place [geofenceId] names.
///
/// - A Place that is not in the snapshot — switched off, deleted, or never
///   written — means nothing happens, and nothing is written.
/// - An exit records when the user left.
/// - An enter starts or continues a visit through [onEnter]; the user is told
///   when something is due and this visit has not told them yet.
Future<void> handleArrivalEvent({
  required String geofenceId,
  required bool isEnter,
  required DateTime nowUtc,
  required ArrivalFiles files,
  required ArrivalNotificationSink sink,
  Random? random,
}) async {
  if (!geofenceId.startsWith(arrivalGeofenceIdPrefix)) return;
  final placeId = geofenceId.substring(arrivalGeofenceIdPrefix.length);

  final snapshot = await files.readSnapshot();
  ArrivalPlace? place;
  for (final candidate in snapshot.places) {
    if (candidate.id == placeId) place = candidate;
  }
  if (place == null) return;

  final visits = await files.readVisits();
  if (!isEnter) {
    visits[placeId] = onExit(visits[placeId], nowUtc: nowUtc);
    await files.writeVisits(visits);
    return;
  }

  final result = onEnter(
    visits[placeId],
    nowUtc: nowUtc,
    somethingDue: place.dueCount > 0,
  );
  final before = visits[placeId];
  visits[placeId] = result.visit;
  await files.writeVisits(visits);

  if (!result.notify) return;
  try {
    await sink.show(
      id: arrivalNotificationId(placeId),
      title: place.name,
      body: arrivalNotificationBody(
        dueCount: place.dueCount,
        dueTitles: place.dueTitles,
        random: random,
      ),
      payload: arrivalNotificationPayload(placeId),
    );
  } catch (_) {
    // The user was not told, so this visit has not told them: put the record
    // back as it was, and the next arrival event tries again.
    if (before == null) {
      visits.remove(placeId);
    } else {
      visits[placeId] = before;
    }
    await files.writeVisits(visits);
    rethrow;
  }
}

/// The sink that shows through `flutter_local_notifications`, in the headless
/// engine the geofence plugin starts.
///
/// That engine has no `main.dart` behind it, so the plugin is initialised here
/// with Android settings only and no callbacks: a tap is dispatched by the app
/// when it launches, from the notification's launch details.
class LocalArrivalNotificationSink implements ArrivalNotificationSink {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void>? _initialized;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    await (_initialized ??= _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    ));
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          arrivalNotificationChannelId,
          arrivalNotificationChannelName,
          channelDescription: arrivalNotificationChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
