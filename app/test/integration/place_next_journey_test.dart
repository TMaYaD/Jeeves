/// The Place gate journey (issue #55), over a real in-memory store.
///
/// An Outcome whose current Action is at a Place leaves the Next list while
/// the user is somewhere else, and comes back when they arrive. With no
/// location — the web, a refused permission, or a phone that has never had a
/// fix — nothing is hidden by place. Up Next is unchanged by a Place.
///
/// The location comes from a recording fake, so the journey can prove that
/// Jeeves reads it only while it is on screen.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Home".
const GeoPoint _home = (
  latitudeDegrees: 52.3702,
  longitudeDegrees: 4.8952,
);

/// A point about 15 m from Home — inside its 150 m area.
const GeoPoint _nearHome = (
  latitudeDegrees: 52.3703,
  longitudeDegrees: 4.8953,
);

/// A point about 40 km away — nowhere near Home.
const GeoPoint _elsewhere = (
  latitudeDegrees: 52.0800,
  longitudeDegrees: 4.3000,
);

Future<String> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
  return (await db.actionDao.getCurrentAction(id))!.id;
}

void main() {
  // The location provider watches the app lifecycle, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  ProviderContainer? container;

  void startContainer() {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  }

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    // The user has allowed the location on this phone: Jeeves listens for
    // positions while it is on screen.
    location.permissionState = LocationPermission.whileInUse;
  });

  tearDown(() async {
    container?.dispose();
    container = null;
    await location.dispose();
    await db.close();
  });

  Future<T> eventually<T>(
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container!.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  /// Waits for a condition that is not a provider's value.
  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 800; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the condition never held');
  }

  Future<Set<String>> nextIds(bool Function(Set<String>) done) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      nextProvider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  /// An Outcome whose current Action is at a Place named "Home".
  Future<void> seedOutcomeAtHome(String outcomeId) async {
    final actionId = await _insertOutcome(db, outcomeId);
    final placeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: _home.latitudeDegrees,
      longitudeDegrees: _home.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    );
    await db.actionDao.setNamedPlace(actionId, placeId);
  }

  test('an Outcome at another Place leaves Next, and comes back on arrival',
      () async {
    await seedOutcomeAtHome('o1');
    await _insertOutcome(db, 'plain');
    // The user is at the office.
    location.freshPoint = _elsewhere;
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), {'plain'});
    // Jeeves is listening to the location while it is on screen.
    await waitUntil(() => location.calls.contains('whileOpen'));

    // The user arrives at Home.
    location.moveTo(_nearHome);
    expect(await nextIds((ids) => ids.contains('o1')), {'o1', 'plain'});
  });

  test('a last known position stands in for a fix that does not arrive',
      () async {
    await seedOutcomeAtHome('o1');
    // No fresh fix, but the OS knows where the phone was.
    location.freshPoint = null;
    location.lastKnownPoint = _nearHome;
    startContainer();

    // The fallback is what puts the user at Home, so the location has to be
    // known before Next is checked: an unknown location leaves 'o1' on Next
    // just as a known one does.
    final known = await eventually<CurrentLocation>(
      currentLocationProvider,
      (v) => v is LocationKnown,
    );
    expect((known as LocationKnown).point, _nearHome);
    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
  });

  test('with no location at all nothing is hidden by place', () async {
    await seedOutcomeAtHome('o1');
    location.freshPoint = null;
    location.lastKnownPoint = null;
    startContainer();

    expect(await nextIds((ids) => ids.contains('o1')), {'o1'});
    // The row still says where the Outcome is.
    final names = await eventually<Map<String, String>>(
      currentPlaceNamesProvider,
      (v) => v.containsKey('o1'),
    );
    expect(names['o1'], 'Home');
  });

  test('nothing is read while Jeeves is off screen, and one fix is read on '
      'resume', () async {
    await seedOutcomeAtHome('o1');
    location.freshPoint = _nearHome;
    startContainer();
    await nextIds((ids) => ids.contains('o1'));
    await waitUntil(() => location.calls.contains('whileOpen'));

    final notifier = container!.read(currentLocationProvider.notifier);
    final readsBeforePause = location.readCalls;
    notifier.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(location.readCalls, readsBeforePause,
        reason: 'nothing is read while Jeeves is off screen');

    notifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await waitUntil(() => location.readCalls == readsBeforePause + 1);
    expect(location.readCalls, readsBeforePause + 1,
        reason: 'resume reads the location once');
  });

  test('Up Next keeps an Outcome that a Place hides from Next', () async {
    await seedOutcomeAtHome('o1');
    location.freshPoint = _elsewhere;
    startContainer();

    expect(await nextIds((ids) => !ids.contains('o1')), isEmpty);
    final upNext = await eventually<AsyncValue<List<Todo>>>(
      nextForFocusSessionPlanningProvider,
      (v) => v.hasValue && v.value!.isNotEmpty,
    );
    expect(upNext.value!.map((t) => t.id), contains('o1'));
  });

  test('a read still waiting for its fix gives up when Jeeves goes off '
      'screen', () async {
    await seedOutcomeAtHome('o1');
    // The fix is on its way and has not arrived.
    location.freshFixGate = Completer<GeoPoint?>();
    startContainer();
    // Nothing watches the location until Jeeves does.
    container!.read(currentLocationProvider);
    await waitUntil(() => location.calls.contains('freshFix'));

    // Jeeves goes off screen while the fix is still coming.
    container!.read(currentLocationProvider.notifier).didChangeAppLifecycleState(
        AppLifecycleState.paused);
    location.freshFixGate!.complete(_nearHome);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(location.calls.contains('whileOpen'), isFalse,
        reason: 'no stream is opened behind a closed app');
  });

  test('the OS\'s cached position is not read after Jeeves goes off screen',
      () async {
    await seedOutcomeAtHome('o1');
    // The fix is on its way and will not arrive.
    location.freshFixGate = Completer<GeoPoint?>();
    location.lastKnownPoint = _nearHome;
    startContainer();
    // Nothing watches the location until Jeeves does.
    container!.read(currentLocationProvider);
    await waitUntil(() => location.calls.contains('freshFix'));

    // Jeeves goes off screen while the fix is still coming.
    container!.read(currentLocationProvider.notifier).didChangeAppLifecycleState(
        AppLifecycleState.paused);
    location.freshFixGate!.complete(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(location.calls.contains('lastKnown'), isFalse,
        reason: 'the cached position is not read behind a closed app');
  });

  test('two resumes in a row open one stream, not two', () async {
    await seedOutcomeAtHome('o1');
    location.freshFixGate = Completer<GeoPoint?>();
    startContainer();
    // Nothing watches the location until Jeeves does.
    container!.read(currentLocationProvider);
    await waitUntil(() => location.calls.contains('freshFix'));

    final notifier = container!.read(currentLocationProvider.notifier);
    notifier.didChangeAppLifecycleState(AppLifecycleState.paused);
    notifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
    notifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
    location.freshFixGate!.complete(_nearHome);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(location.calls.where((call) => call == 'whileOpen').length, 1,
        reason: 'one stream, not one per resume');
  });

  test('the position stream stops when Jeeves goes off screen', () async {
    await seedOutcomeAtHome('o1');
    location.freshPoint = _nearHome;
    startContainer();
    await nextIds((ids) => ids.contains('o1'));
    await waitUntil(() => location.calls.contains('whileOpen'));

    final notifier = container!.read(currentLocationProvider.notifier);
    notifier.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The user moves; Jeeves is off screen and hears nothing.
    location.moveTo(_elsewhere);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container!.read(currentLocationProvider),
      isA<LocationKnown>().having((known) => known.point, 'point', _nearHome),
    );
  });
}
