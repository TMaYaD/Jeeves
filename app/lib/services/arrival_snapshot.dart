/// The device-local arrival snapshot — the Outcomes and Habits due at each
/// Place the user asked to hear about on arrival (issues #1092, #1095).
///
/// The arrival notification is raised while Jeeves is closed, and the
/// background code may not open the store. So the foreground app writes down
/// what the background code needs, and the background code reads that down
/// instead.
///
/// The snapshot is a **copy**, not the truth: it says what was due the last
/// time Jeeves was open. An Outcome finished on another device stays in it
/// until Jeeves next runs here. The store is the truth; this is the copy of it
/// that travels to the background.
///
/// Two files, both in the app's private support directory, both never synced:
///
/// - `arrival_snapshot.json` — the Places and what is due at each.
/// - `arrival_visits.json` — what the phone remembers about the visits.
///
/// A file that is missing, empty or unreadable reads as empty: a phone that
/// has never been here has nothing to say, and a file that cannot be read is
/// no reason to crash the app that is running.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'arrival_visit_rule.dart';

/// The name of the file holding the snapshot.
const String arrivalSnapshotFileName = 'arrival_snapshot.json';

/// The name of the file holding the visit record.
const String arrivalVisitsFileName = 'arrival_visits.json';

/// The name of the file holding the areas Jeeves last registered with the OS.
const String arrivalGeofencesFileName = 'arrival_geofences.json';

/// The version of the format this build writes.
const int arrivalSnapshotFormatVersion = 1;

/// One Habit due at a Place, and the days over the horizon it is for.
///
/// A day key is a local calendar day, `YYYY-MM-DD`. The arrival can come days
/// after Jeeves was last open, so the snapshot carries the days ahead and the
/// background code picks today's.
typedef ArrivalHabit = ({String title, List<String> forDayKeys});

/// One Place the user asked to hear about, and what is due there.
///
/// [dueCount] and [dueTitles] are the Outcomes due; [dueHabits] are the Habits.
typedef ArrivalPlace = ({
  String id,
  String name,
  int latitudeMicrodegrees,
  int longitudeMicrodegrees,
  int radiusMeters,
  int dueCount,
  List<String> dueTitles,
  List<ArrivalHabit> dueHabits,
});

/// The switched-on Places, and what is due at each of them.
typedef ArrivalSnapshot = ({List<ArrivalPlace> places});

/// The snapshot of a phone that has nothing switched on.
const ArrivalSnapshot emptyArrivalSnapshot = (places: <ArrivalPlace>[]);

/// How many titles the snapshot carries for one Place.
const int arrivalDueTitlesLimit = 3;

/// How many days ahead, today included, the snapshot says which Habits are for.
const int arrivalHabitHorizonDays = 7;

/// Encodes a snapshot as the text of `arrival_snapshot.json`.
String encodeArrivalSnapshot(ArrivalSnapshot snapshot) => jsonEncode({
      'version': arrivalSnapshotFormatVersion,
      'places': [
        for (final place in snapshot.places)
          {
            'id': place.id,
            'name': place.name,
            'latitudeMicrodegrees': place.latitudeMicrodegrees,
            'longitudeMicrodegrees': place.longitudeMicrodegrees,
            'radiusMeters': place.radiusMeters,
            'dueCount': place.dueCount,
            'dueTitles': place.dueTitles,
            'dueHabits': [
              for (final habit in place.dueHabits)
                {'title': habit.title, 'forDayKeys': habit.forDayKeys},
            ],
          },
      ],
    });

/// Decodes the text of `arrival_snapshot.json`.
///
/// A text that cannot be read — not JSON, not the shape this build writes —
/// reads as an empty snapshot rather than raising: the arrival path must never
/// be the reason the app falls over. A single unreadable Place is skipped,
/// and the rest of the snapshot stands.
ArrivalSnapshot decodeArrivalSnapshot(String source) {
  final decoded = _decodeObject(source);
  if (decoded == null) return emptyArrivalSnapshot;
  final rawPlaces = decoded['places'];
  if (rawPlaces is! List) return emptyArrivalSnapshot;

  final places = <ArrivalPlace>[];
  for (final entry in rawPlaces) {
    if (entry is! Map) continue;
    final id = entry['id'];
    if (id is! String || id.isEmpty) continue;
    places.add((
      id: id,
      name: _readString(entry['name']),
      latitudeMicrodegrees: _readInt(entry['latitudeMicrodegrees']),
      longitudeMicrodegrees: _readInt(entry['longitudeMicrodegrees']),
      radiusMeters: _readInt(entry['radiusMeters']),
      dueCount: _readInt(entry['dueCount']),
      dueTitles: _readStringList(entry['dueTitles']),
      dueHabits: _readHabits(entry['dueHabits']),
    ));
  }
  if (places.isEmpty) return emptyArrivalSnapshot;
  return (places: places);
}

/// Encodes the visit record as the text of `arrival_visits.json`.
String encodeVisitRecord(Map<String, PlaceVisit> visits) => jsonEncode({
      'version': arrivalSnapshotFormatVersion,
      'visits': {
        for (final entry in visits.entries)
          entry.key: {
            'inside': entry.value.inside,
            'lastExitAtUtc': entry.value.lastExitAtUtc?.toUtc().toIso8601String(),
            'notifiedThisVisit': entry.value.notifiedThisVisit,
          },
      },
    });

/// Decodes the text of `arrival_visits.json`.
///
/// As with the snapshot, a text that cannot be read reads as no visits at
/// all: the phone then treats the next arrival as the first of a new visit,
/// which is the safe way to be wrong.
Map<String, PlaceVisit> decodeVisitRecord(String source) {
  final decoded = _decodeObject(source);
  if (decoded == null) return <String, PlaceVisit>{};
  final rawVisits = decoded['visits'];
  if (rawVisits is! Map) return <String, PlaceVisit>{};

  final visits = <String, PlaceVisit>{};
  for (final entry in rawVisits.entries) {
    if (entry.key is! String || entry.key.isEmpty) continue;
    if (entry.value is! Map) continue;
    final visit = entry.value as Map;
    visits[entry.key as String] = (
      inside: visit['inside'] == true,
      lastExitAtUtc: _readInstant(visit['lastExitAtUtc']),
      notifiedThisVisit: visit['notifiedThisVisit'] == true,
    );
  }
  return visits;
}

/// The two files the arrival path reads and writes on this device.
class ArrivalFiles {
  ArrivalFiles(this.directory);

  /// The files where they live in the running app: the app's own private
  /// support directory.
  static Future<ArrivalFiles> inApplicationSupport() async =>
      ArrivalFiles(await getApplicationSupportDirectory());

  /// The directory the two files live in.
  final Directory directory;

  /// The file holding the snapshot.
  File get snapshotFile => File(p.join(directory.path, arrivalSnapshotFileName));

  /// The file holding the visit record.
  File get visitsFile => File(p.join(directory.path, arrivalVisitsFileName));

  /// The file holding the areas last registered with the OS, by Place id.
  /// Only the foreground app reads it.
  File get geofencesFile => File(p.join(directory.path, arrivalGeofencesFileName));

  /// Reads the snapshot. A file that is missing or unreadable reads as empty.
  Future<ArrivalSnapshot> readSnapshot() async {
    try {
      final source = await snapshotFile.readAsString();
      return decodeArrivalSnapshot(source);
    } on Object {
      return emptyArrivalSnapshot;
    }
  }

  /// Writes the snapshot, so that a reader never sees half of one.
  Future<void> writeSnapshot(ArrivalSnapshot snapshot) =>
      _writeAtomically(snapshotFile, encodeArrivalSnapshot(snapshot));

  /// Reads the visit record. A file that is missing or unreadable reads as
  /// empty.
  Future<Map<String, PlaceVisit>> readVisits() async {
    try {
      final source = await visitsFile.readAsString();
      return decodeVisitRecord(source);
    } on Object {
      return <String, PlaceVisit>{};
    }
  }

  /// Writes the visit record, so that a reader never sees half of one.
  Future<void> writeVisits(Map<String, PlaceVisit> visits) =>
      _writeAtomically(visitsFile, encodeVisitRecord(visits));

  /// Reads the areas last registered with the OS, by Place id. A file that is
  /// missing or unreadable reads as none: every Place is then registered
  /// again, which is the safe way to be wrong.
  Future<Map<String, String>> readRegisteredAreas() async {
    try {
      final decoded = _decodeObject(await geofencesFile.readAsString());
      final areas = decoded?['areas'];
      if (areas is! Map) return <String, String>{};
      return {
        for (final entry in areas.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on Object {
      return <String, String>{};
    }
  }

  /// Writes the areas last registered with the OS.
  Future<void> writeRegisteredAreas(Map<String, String> areas) =>
      _writeAtomically(
        geofencesFile,
        jsonEncode({'version': arrivalSnapshotFormatVersion, 'areas': areas}),
      );

  /// Writes [text] to [file] through a temporary file, so that a reader — the
  /// background arrival code — sees either the old file or the new one, never
  /// half of the new one.
  Future<void> _writeAtomically(File file, String text) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }
}

/// The JSON object [source] holds, or null when it holds no object.
Map<String, Object?>? _decodeObject(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) return null;
    return decoded.cast<String, Object?>();
  } on FormatException {
    return null;
  }
}

/// The string [value] holds, or the empty string.
String _readString(Object? value) => value is String ? value : '';

/// The int [value] holds, or zero.
int _readInt(Object? value) => value is int ? value : 0;

/// The strings [value] holds, or none.
List<String> _readStringList(Object? value) {
  if (value is! List) return const <String>[];
  return [
    for (final entry in value)
      if (entry is String) entry,
  ];
}

/// The Habits [value] holds. A missing field, or an entry without a title,
/// reads as no Habit; a day that is not a string is skipped.
List<ArrivalHabit> _readHabits(Object? value) {
  if (value is! List) return const <ArrivalHabit>[];
  final habits = <ArrivalHabit>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final title = entry['title'];
    if (title is! String || title.isEmpty) continue;
    habits.add((title: title, forDayKeys: _readStringList(entry['forDayKeys'])));
  }
  return habits;
}

/// The instant [value] holds, or null.
DateTime? _readInstant(Object? value) {
  if (value is! String) return null;
  final parsed = DateTime.tryParse(value);
  return parsed?.toUtc();
}
