/// The phone's own time zone (issue #1074).
///
/// A place takes the phone's zone as the default for its own hours, so this
/// is the zone a place reads on until the user names another one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

/// The IANA name of the phone's own time zone (`Europe/Amsterdam`), or null
/// when the phone does not say.
///
/// A phone that does not answer has no zone to offer: the hours are then read
/// on the phone's clock, which is where they are read anyway.
final phoneTimeZoneNameProvider = FutureProvider<String?>((ref) async {
  try {
    // flutter_timezone 5.x returns TimezoneInfo; .identifier gives the IANA
    // string.
    final info = await FlutterTimezone.getLocalTimezone();
    return info.identifier;
  } on Object {
    return null;
  }
});
