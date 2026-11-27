import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/place_time_zone.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  test('loads the tz database when it is not loaded', () {
    // The helper must not depend on the app having started: it loads the tz
    // database itself, not NotificationService.
    tz.timeZoneDatabase.clear();
    expect(tz.timeZoneDatabase.isInitialized, isFalse);

    expect(placeTimeZoneLocation('Europe/Berlin'), isNotNull);
    expect(tz.timeZoneDatabase.isInitialized, isTrue);
  });

  test('resolves a known zone by its IANA name', () {
    final berlin = placeTimeZoneLocation('Europe/Berlin');
    expect(berlin, isNotNull);
    expect(berlin!.name, 'Europe/Berlin');

    final newYork = placeTimeZoneLocation('America/New_York');
    expect(newYork, isNotNull);
    expect(newYork!.name, 'America/New_York');
  });

  test('an unknown zone name is null', () {
    expect(placeTimeZoneLocation('Nowhere/Special'), isNull);
  });

  test('a blank zone name is null', () {
    expect(placeTimeZoneLocation(''), isNull);
    expect(placeTimeZoneLocation('   '), isNull);
  });

  group('zoneCityLabel', () {
    test('reads the city of a zone name', () {
      expect(zoneCityLabel('America/New_York'), 'New York');
    });

    test('reads the city of a zone in a region', () {
      expect(zoneCityLabel('Europe/Berlin'), 'Berlin');
    });

    test('reads the last segment of a zone name', () {
      expect(zoneCityLabel('America/Argentina/Buenos_Aires'), 'Buenos Aires');
    });

    test('a zone with no region reads as itself', () {
      expect(zoneCityLabel('UTC'), 'UTC');
    });

    test('a blank name reads as blank', () {
      expect(zoneCityLabel(''), '');
    });
  });
}
