/// The arrival snapshot codec (issue #1092).
///
/// The snapshot is what the background arrival code reads while Jeeves is
/// closed. It has to survive a round trip through a file, and a file that
/// cannot be read must never be the reason the app falls over.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/services/arrival_snapshot.dart';
import 'package:jeeves/services/arrival_visit_rule.dart';

/// Whether two snapshots say the same thing.
///
/// A record compares its lists by identity, so the Places are compared one by
/// one instead.
bool sameSnapshot(ArrivalSnapshot a, ArrivalSnapshot b) {
  if (a.places.length != b.places.length) return false;
  for (var index = 0; index < a.places.length; index++) {
    final first = a.places[index];
    final second = b.places[index];
    if (first.id != second.id) return false;
    if (first.name != second.name) return false;
    if (first.latitudeMicrodegrees != second.latitudeMicrodegrees) return false;
    if (first.longitudeMicrodegrees != second.longitudeMicrodegrees) return false;
    if (first.radiusMeters != second.radiusMeters) return false;
    if (first.dueCount != second.dueCount) return false;
    if (first.dueTitles.length != second.dueTitles.length) return false;
    for (var title = 0; title < first.dueTitles.length; title++) {
      if (first.dueTitles[title] != second.dueTitles[title]) return false;
    }
    if (first.dueHabits.length != second.dueHabits.length) return false;
    for (var habit = 0; habit < first.dueHabits.length; habit++) {
      final a = first.dueHabits[habit];
      final b = second.dueHabits[habit];
      if (a.title != b.title) return false;
      if (a.forDayKeys.join(',') != b.forDayKeys.join(',')) return false;
    }
  }
  return true;
}

/// Whether two visit records say the same thing.
bool sameVisits(Map<String, PlaceVisit> a, Map<String, PlaceVisit> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null) return false;
    if (other.inside != entry.value.inside) return false;
    if (other.notifiedThisVisit != entry.value.notifiedThisVisit) return false;
    if (other.lastExitAtUtc != entry.value.lastExitAtUtc) return false;
  }
  return true;
}

void main() {
  group('the snapshot', () {
    const ArrivalSnapshot snapshot = (
      places: [
        (
          id: 'place-1',
          name: 'Hardware store',
          latitudeMicrodegrees: 52370200,
          longitudeMicrodegrees: 4895200,
          radiusMeters: 150,
          dueCount: 2,
          dueTitles: ['Buy screws', 'Return the drill'],
          dueHabits: [
            (title: 'Workout', forDayKeys: ['2026-11-28', '2026-11-30']),
          ],
        ),
        (
          id: 'place-2',
          name: 'Corner shop',
          latitudeMicrodegrees: 52370300,
          longitudeMicrodegrees: 4895300,
          radiusMeters: 300,
          dueCount: 0,
          dueTitles: [],
          dueHabits: [],
        ),
      ],
    );

    test('survives a round trip through its encoded form', () {
      expect(sameSnapshot(decodeArrivalSnapshot(encodeArrivalSnapshot(snapshot)), snapshot),
          isTrue);
    });

    test('reads as empty when the text is not a snapshot', () {
      expect(decodeArrivalSnapshot('this is not a snapshot'),
          emptyArrivalSnapshot);
      expect(decodeArrivalSnapshot('{"places": 7}'), emptyArrivalSnapshot);
    });

    test('reads a snapshot written before Habits as having no Habits', () {
      final decoded = decodeArrivalSnapshot(
        '{"version": 1, "places": [{"id": "place-1", "name": "Home", '
        '"dueCount": 1, "dueTitles": ["Buy screws"]}]}',
      );

      expect(decoded.places.single.dueHabits, isEmpty);
      expect(decoded.places.single.dueTitles, ['Buy screws']);
    });

    test('skips a Habit without a title and a day that is not a string', () {
      final decoded = decodeArrivalSnapshot(
        '{"places": [{"id": "place-1", "dueHabits": ['
        '{"forDayKeys": ["2026-11-28"]}, '
        '{"title": "Workout", "forDayKeys": ["2026-11-28", 7]}]}]}',
      );

      final habits = decoded.places.single.dueHabits;
      expect(habits, hasLength(1));
      expect(habits.single.title, 'Workout');
      expect(habits.single.forDayKeys, ['2026-11-28']);
    });

    test('skips a Place that cannot be read, and keeps the rest', () {
      final decoded = decodeArrivalSnapshot(
        '{"places": [{"name": "No id"}, {"id": "place-1", "name": "Home"}]}',
      );

      expect(decoded.places, hasLength(1));
      expect(decoded.places.single.id, 'place-1');
      expect(decoded.places.single.name, 'Home');
    });
  });

  group('the visit record', () {
    final visits = {
      'place-1': (
        inside: false,
        lastExitAtUtc: DateTime.utc(2026, 11, 26, 9, 30),
        notifiedThisVisit: true,
      ),
      'place-2': (
        inside: true,
        lastExitAtUtc: null,
        notifiedThisVisit: false,
      ),
    };

    test('survives a round trip through its encoded form', () {
      expect(sameVisits(decodeVisitRecord(encodeVisitRecord(visits)), visits),
          isTrue);
    });

    test('reads as empty when the text is not a visit record', () {
      expect(decodeVisitRecord('this is not a visit record'), isEmpty);
      expect(decodeVisitRecord('{"visits": 7}'), isEmpty);
    });
  });

  group('the files', () {
    late Directory directory;
    late ArrivalFiles files;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jeeves-arrival-files');
      files = ArrivalFiles(directory);
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('a file that is not there reads as empty', () async {
      expect(await files.readSnapshot(), emptyArrivalSnapshot);
      expect(await files.readVisits(), isEmpty);
    });

    test('a file that cannot be read reads as empty', () async {
      await files.snapshotFile.writeAsString('this is not a snapshot');
      await files.visitsFile.writeAsString('this is not a visit record');

      expect(await files.readSnapshot(), emptyArrivalSnapshot);
      expect(await files.readVisits(), isEmpty);
    });

    test('a written snapshot is read back', () async {
      const ArrivalSnapshot snapshot = (
        places: [
          (
            id: 'place-1',
            name: 'Hardware store',
            latitudeMicrodegrees: 52370200,
            longitudeMicrodegrees: 4895200,
            radiusMeters: 150,
            dueCount: 1,
            dueTitles: ['Buy screws'],
            dueHabits: [],
          ),
        ],
      );

      await files.writeSnapshot(snapshot);

      expect(sameSnapshot(await files.readSnapshot(), snapshot), isTrue);
    });

    test('a written visit record is read back', () async {
      final visits = {
        'place-1': (
          inside: false,
          lastExitAtUtc: DateTime.utc(2026, 11, 26, 9, 30),
          notifiedThisVisit: true,
        ),
      };

      await files.writeVisits(visits);

      expect(sameVisits(await files.readVisits(), visits), isTrue);
    });
  });
}
