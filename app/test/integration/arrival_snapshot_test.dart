/// The arrival snapshot journey (issue #1092), over a real store and the
/// real providers.
///
/// The background arrival code may not open the store, so the foreground app
/// writes down what is due at each Place the user asked to hear about. This
/// journey proves that the snapshot says what it should: the Outcomes due at
/// a switched-on Place, and nothing else.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/providers/arrival_notification_settings.dart';
import 'package:jeeves/providers/arrival_snapshot_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/arrival_snapshot.dart';
import 'package:jeeves/services/arrival_visit_rule.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Hardware store".
const double _storeLatitude = 52.3702;
const double _storeLongitude = 4.8952;

/// The point of the Place named "Corner shop".
const double _shopLatitude = 52.3710;
const double _shopLongitude = 4.8960;

/// The point of the one-time pin.
const double _pinLatitude = 52.3720;
const double _pinLongitude = 4.8970;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late Directory directory;
  late ArrivalFiles files;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    directory = Directory.systemTemp.createTempSync('jeeves-arrival-snapshot');
    files = ArrivalFiles(directory);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      arrivalFilesProvider.overrideWith((ref) async => files),
    ]);
    addTearDown(container.dispose);
    // Nothing else reads the reconciler, so without this it would never run —
    // the same watch `main.dart` makes.
    container.listen(arrivalSnapshotReconcilerProvider, (_, _) {});
  });

  tearDown(() async {
    await db.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Creates a named Place and returns its id.
  Future<String> createPlace(String name, double latitude, double longitude) async {
    final id = await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: latitude,
      longitudeDegrees: longitude,
      radiusMeters: 150,
      userId: _userId,
    );
    return id!;
  }

  /// Creates an Outcome with a current Action, and returns the Action's id.
  Future<String> createOutcome(String id, String title) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value(title),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db, outcomeId: id, text: 'work on $title', userId: _userId);
    return (await db.actionDao.getCurrentAction(id))!.id;
  }

  /// Puts the Outcome at a named Place.
  Future<void> putAtPlace(String outcomeId, String placeId) async {
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setNamedPlace(actionId, placeId);
  }

  /// Puts the Outcome at a one-time pin of its own.
  Future<void> putAtPin(String outcomeId) async {
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setPin(
      actionId,
      PlaceArea.create(
        latitudeDegrees: _pinLatitude,
        longitudeDegrees: _pinLongitude,
      )!,
    );
  }

  /// Gives the Outcome a time window that closed earlier today.
  Future<void> closeItsTimeWindow(String outcomeId) async {
    final windowId = await db.timeWindowDao.createTimeWindow(
      name: 'Early',
      // One minute after midnight, on every day: closed by the time the test
      // runs, whatever hour it is.
      hours: {
        for (var day = 1; day <= 7; day++)
          day: (startMinute: 1, endMinute: 2),
      },
      userId: _userId,
    );
    final actionId = (await db.actionDao.getCurrentAction(outcomeId))!.id;
    await db.actionDao.setTimeWindow(actionId, windowId);
  }

  /// Waits for the snapshot on disk to say what the test waits for.
  Future<ArrivalSnapshot> waitForSnapshot(
    bool Function(ArrivalSnapshot snapshot) done,
  ) async {
    ArrivalSnapshot last = emptyArrivalSnapshot;
    for (var attempt = 0; attempt < 800; attempt++) {
      last = await files.readSnapshot();
      if (done(last)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final raw = files.snapshotFile.existsSync()
        ? files.snapshotFile.readAsStringSync()
        : '(no file)';
    fail('the arrival snapshot never held what the test waited for.\n'
        'file: $raw');
  }

  /// Waits for the visit record on disk to say what the test waits for.
  Future<Map<String, PlaceVisit>> waitForVisits(
    bool Function(Map<String, PlaceVisit> visits) done,
  ) async {
    for (var attempt = 0; attempt < 800; attempt++) {
      final visits = await files.readVisits();
      if (done(visits)) return visits;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the visit record never held what the test waited for');
  }

  /// The Place with [id] in the snapshot, or null.
  ArrivalPlace? placeIn(ArrivalSnapshot snapshot, String id) {
    for (final place in snapshot.places) {
      if (place.id == id) return place;
    }
    return null;
  }

  test('the snapshot holds what is due at a switched-on Place, and nothing '
      'else', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    final shopId = await createPlace('Corner shop', _shopLatitude, _shopLongitude);

    // Two Outcomes at the hardware store: one plainly due, and one whose time
    // window closed earlier today. The time of day makes no difference to the
    // arrival notification — the user is at the Place, and the Outcome is
    // there.
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await createOutcome('o-drill', 'Return the drill');
    await putAtPlace('o-drill', storeId);
    await closeItsTimeWindow('o-drill');

    // An Outcome at a one-time pin: a pin belongs to a single Action and is
    // never listed, so it is never a Place to arrive at.
    await createOutcome('o-pin', 'Find the shed');
    await putAtPin('o-pin');

    // An Outcome at a Place the user did not switch on.
    await createOutcome('o-shop', 'Milk');
    await putAtPlace('o-shop', shopId);

    // The user asked to hear about the hardware store only.
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    final snapshot = await waitForSnapshot(
      (snapshot) => (placeIn(snapshot, storeId)?.dueCount ?? 0) == 2,
    );

    final store = placeIn(snapshot, storeId)!;
    expect(store.name, 'Hardware store');
    expect(store.dueCount, 2);
    expect(store.dueTitles, contains('Buy screws'));
    expect(store.dueTitles, contains('Return the drill'));
    expect(store.latitudeMicrodegrees, 52370200);
    expect(store.longitudeMicrodegrees, 4895200);
    expect(store.radiusMeters, 150);

    // The Place with the switch off is not in the snapshot, and neither is
    // the pin: the snapshot holds the switched-on Place and nothing else.
    expect(placeIn(snapshot, shopId), isNull);
    expect(snapshot.places, hasLength(1));
  });

  test('finishing an Outcome takes it out of the snapshot', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    await waitForSnapshot(
      (snapshot) => (placeIn(snapshot, storeId)?.dueCount ?? 0) == 1,
    );

    // The user finishes it.
    await db.todoDao.markDone('o-screws');

    final snapshot = await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId)?.dueCount == 0,
    );
    expect(placeIn(snapshot, storeId)!.dueTitles, isEmpty);
  });

  test('switching a Place off takes it and its visit out', () async {
    final storeId = await createPlace('Hardware store', _storeLatitude, _storeLongitude);
    await createOutcome('o-screws', 'Buy screws');
    await putAtPlace('o-screws', storeId);
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOn(storeId);

    await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId) != null,
    );

    // The phone remembers a visit at that Place.
    await files.writeVisits({
      storeId: (
        inside: false,
        lastExitAtUtc: DateTime.utc(2026, 11, 26, 9, 30),
        notifiedThisVisit: true,
      ),
    });

    // The user switches the Place off.
    await container
        .read(arrivalPlaceIdsProvider.notifier)
        .turnOff(storeId);

    final snapshot = await waitForSnapshot(
      (snapshot) => placeIn(snapshot, storeId) == null,
    );
    expect(snapshot.places, isEmpty);

    // The visit at a Place Jeeves no longer watches is gone too.
    final visits = await waitForVisits((visits) => !visits.containsKey(storeId));
    expect(visits, isEmpty);
  });
}
