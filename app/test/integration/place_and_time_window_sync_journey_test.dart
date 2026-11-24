/// The Place and time window journey (issue #239), over two devices.
///
/// A Place and a named time window made on one device reach the other, a
/// rename travels back, and a delete detaches. Two devices that edit the same
/// Action while apart settle on one Place, and a Place deleted on one device
/// resolves to no place on both — a reference that names nothing never hides
/// an Action.
///
/// The two-device harness lives in `test/sync/harness/`, the same one the
/// collection round-trip suite drives.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/sync/ids.dart' show jeevesWorkspaceNamespace;
import 'package:uuid/uuid.dart';

import '../sync/harness/reduced_state.dart';
import '../sync/harness/sim_device.dart';
import '../sync/harness/sim_workspace.dart';
import '../test_helpers.dart';

const _userId = 'sim-user';

/// Entity ids are canonical lowercase UUIDs on the wire, so a fixture id like
/// 'outcome-1' would be refused by `capture()` itself. Deriving them keeps the
/// harness reproducible without hand-writing UUID literals.
String _id(String label) => const Uuid().v5(jeevesWorkspaceNamespace, 'sim/$label');

void main() {
  setUpAll(configureSqliteForTests);

  late SimWorkspace workspace;
  late SimDevice a;
  late SimDevice b;

  setUp(() async {
    workspace = await SimWorkspace.create();
    a = workspace.a;
    b = workspace.b;
  });
  tearDown(() async => workspace.close());

  /// An Outcome with a current Action, made on [device].
  Future<String> outcomeWithAction(SimDevice device, String label) async {
    final id = _id(label);
    await device.domain.todoDao.insertOutcome(
      id: id,
      title: 'Buy a hammer',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    await device.domain.todoDao.setCurrentActionText(
      id,
      'Buy a hammer',
      now: device.clock.asDateTime,
    );
    return id;
  }

  Future<String> actionIdOf(SimDevice device, String outcomeId) async =>
      (await device.domain.actionDao.getCurrentAction(outcomeId))!.id;

  Future<String> hardwareStoreOn(SimDevice device) async {
    final id = await device.domain.placeDao.createNamedPlace(
      name: 'Hardware store',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 300,
      userId: _userId,
      now: device.clock.asDateTime,
    );
    return id!;
  }

  Future<String> storeHoursOn(SimDevice device) async {
    final id = await device.domain.timeWindowDao.createTimeWindow(
      name: 'Store hours',
      hours: {
        for (var day = 1; day <= 5; day++)
          day: (startMinute: 11 * 60, endMinute: 20 * 60),
      },
      userId: _userId,
      now: device.clock.asDateTime,
    );
    return id!;
  }

  test('a Place and a time window made on A reach B, and a rename and a '
      'delete travel back', () async {
    final outcomeId = await outcomeWithAction(a, 'outcome-1');
    final actionId = await actionIdOf(a, outcomeId);
    final placeId = await hardwareStoreOn(a);
    final windowId = await storeHoursOn(a);

    await a.domain.actionDao
        .setNamedPlace(actionId, placeId, now: a.clock.asDateTime);
    await a.domain.actionDao
        .setTimeWindow(actionId, windowId, now: a.clock.asDateTime);

    await workspace.syncAll();

    // On B: the place, the window, and the Action's resolved pair.
    final placeOnB = await b.domain.placeDao.watchNamedPlaces().first;
    expect(placeOnB.single.id, placeId);
    expect(placeOnB.single.name, 'Hardware store');
    expect(placeOnB.single.radiusMeters, 300);

    final windowOnB = await b.domain.timeWindowDao.watchTimeWindows().first;
    expect(windowOnB.single.id, windowId);
    expect(windowOnB.single.name, 'Store hours');

    final resolvedOnB =
        await b.domain.actionDao.placeAndTimeWindowFor(actionId);
    expect(resolvedOnB.place!.id, placeId);
    expect(resolvedOnB.place!.name, 'Hardware store');
    expect(resolvedOnB.place!.area.radiusMeters, 300);
    expect(resolvedOnB.timeWindow!.id, windowId);
    expect(resolvedOnB.timeWindow!.name, 'Store hours');
    expect(resolvedOnB.timeWindow!.hours.hoursForDay(1),
        (startMinute: 11 * 60, endMinute: 20 * 60));
    expect(await domainRows(b.domain, 'places'),
        await domainRows(a.domain, 'places'));

    // A rename made on B travels back to A.
    a.clock.advance(1000);
    await b.domain.placeDao.updateNamedPlace(
      placeId: placeId,
      name: 'Hardware store (B&Q)',
      now: b.clock.asDateTime,
    );
    await workspace.syncAll();
    expect((await a.domain.placeDao.watchNamedPlaces().first).single.name,
        'Hardware store (B&Q)');

    // A delete made on A detaches the window on both.
    a.clock.advance(1000);
    await a.domain.timeWindowDao
        .deleteTimeWindow(windowId, now: a.clock.asDateTime);
    await workspace.syncAll();

    expect(await b.domain.timeWindowDao.watchTimeWindows().first, isEmpty);
    final afterDelete =
        await b.domain.actionDao.placeAndTimeWindowFor(actionId);
    expect(afterDelete.timeWindow, isNull);
    expect(afterDelete.place!.id, placeId);
  });

  test('a named Place on one device and a pin on the other settle on one '
      'Place', () async {
    final outcomeId = await outcomeWithAction(a, 'outcome-1');
    await workspace.syncAll();
    final actionId = await actionIdOf(b, outcomeId);

    // The two devices edit the same Action while apart.
    a.goOffline();
    b.goOffline();

    final placeId = await hardwareStoreOn(a);
    await a.domain.actionDao
        .setNamedPlace(actionId, placeId, now: a.clock.asDateTime);

    final pinId = await b.domain.actionDao.setPin(
      actionId,
      PlaceArea.create(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278)!,
      now: b.clock.asDateTime,
    );

    a.goOnline();
    b.goOnline();
    await workspace.syncAll();

    // One Place on the Action, and the same one on both devices.
    final onA = await a.domain.actionDao.placeAndTimeWindowFor(actionId);
    final onB = await b.domain.actionDao.placeAndTimeWindowFor(actionId);
    expect(onA.place, isNotNull);
    expect(onB.place!.id, onA.place!.id);
    expect([placeId, pinId], contains(onA.place!.id));
  });

  test('a Place deleted on one device resolves to no place on both',
      () async {
    final firstOutcome = await outcomeWithAction(a, 'outcome-1');
    final secondOutcome = await outcomeWithAction(a, 'outcome-2');
    final placeId = await hardwareStoreOn(a);
    final firstAction = await actionIdOf(a, firstOutcome);
    final secondAction = await actionIdOf(a, secondOutcome);
    await a.domain.actionDao
        .setNamedPlace(firstAction, placeId, now: a.clock.asDateTime);
    await workspace.syncAll();

    // The devices edit apart: A deletes the Place, B attaches it to the
    // other Action.
    a.goOffline();
    b.goOffline();

    await a.domain.placeDao.deletePlace(placeId, now: a.clock.asDateTime);
    await b.domain.actionDao
        .setNamedPlace(secondAction, placeId, now: b.clock.asDateTime);

    a.goOnline();
    b.goOnline();
    await workspace.syncAll();

    for (final device in [a, b]) {
      final first =
          await device.domain.actionDao.placeAndTimeWindowFor(firstAction);
      final second =
          await device.domain.actionDao.placeAndTimeWindowFor(secondAction);
      expect(first.place, isNull,
          reason: '${device.label} kept the deleted Place');
      expect(second.place, isNull,
          reason: '${device.label} resolved a Place that no longer exists');
      expect(await device.domain.placeDao.watchNamedPlaces().first, isEmpty);
    }
  });
}
