/// The Timeboxed switch reaches the user's other devices, like the estimate
/// it sits beside (issue #923).
///
/// Two real devices (real domain store, real sync store, real DAOs, real
/// merge) joined by the in-memory relay plugin: the merge rule is tested at
/// the sync-host level, so no concrete plugin is needed.
///
/// The switch is Action metadata, so it rides the `actions` collection — the
/// same collection the estimate rides, and the same merge.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/timeboxed.dart';
import 'package:jeeves/sync/host/change.dart';

import 'host_harness.dart';

const String _userId = 'timeboxed-user';
const String _outcomeId = '9c8b7a6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';

final DateTime _t0 = DateTime.utc(2026, 7, 28, 9);

class _Pair {
  _Pair(this.a, this.b, this.sync);
  final HostDevice a;
  final HostDevice b;
  final Future<void> Function() sync;
}

/// Two devices, one Outcome with a current Action of [timeEstimate] minutes.
Future<_Pair> _pair({int? timeEstimate = 30}) async {
  final relay = <({String origin, Change change})>[];
  final a = HostDevice.open('a');
  final b = HostDevice.open('b');
  addTearDown(a.close);
  addTearDown(b.close);
  final hostA = await a.startHost();
  final hostB = await b.startHost();
  final pluginA = RelayPlugin('relay', relay)..origin = 'a';
  final pluginB = RelayPlugin('relay', relay)..origin = 'b';
  await hostA.attach(pluginA);
  await hostB.attach(pluginB);
  Future<void> sync() async {
    await hostA.deliverAll();
    await hostB.deliverAll();
    await pluginA.pull();
    await pluginB.pull();
    await hostA.deliverAll();
    await hostB.deliverAll();
  }

  await a.domain.todoDao.insertOutcome(
    id: _outcomeId,
    title: 'Renew the passport',
    userId: _userId,
  );
  await a.domain.actionDao.setCurrentAction(
    _outcomeId,
    'Renew the passport',
    timeEstimate: timeEstimate,
    now: _t0,
  );
  await sync();
  return _Pair(a, b, sync);
}

/// The current Action, as the device holds it.
Future<Action?> _action(HostDevice device) =>
    device.domain.actionDao.getCurrentAction(_outcomeId);

void main() {
  test('an estimate and the switch written together reach the other device',
      () async {
    final pair = await _pair(timeEstimate: null);
    // The path the app takes: the estimate sheet writes the estimate and the
    // switch together, in one row write with one timestamp.
    await pair.a.domain.todoDao.updateFields(
      _outcomeId,
      timeEstimate: 30,
      timeboxed: true,
      now: _t0,
    );
    await pair.sync();

    final onB = (await _action(pair.b))!;
    expect(onB.timeboxed, isTrue);
    expect(onB.timeEstimate, 30);
    expect(
      isTimeboxedAction(
        timeboxed: onB.timeboxed,
        timeEstimate: onB.timeEstimate,
      ),
      isTrue,
    );
  });

  test('the switch turned on at A reads on at B', () async {
    final pair = await _pair();
    await pair.a.domain.todoDao.updateFields(
      _outcomeId,
      timeboxed: true,
      now: _t0,
    );
    await pair.sync();

    final onB = (await _action(pair.b))!;
    expect(onB.timeboxed, isTrue);
    // The switch means nothing without the estimate beside it, and the
    // estimate is there.
    expect(
      isTimeboxedAction(
        timeboxed: onB.timeboxed,
        timeEstimate: onB.timeEstimate,
      ),
      isTrue,
    );
    expect(onB.timeEstimate, 30);
  });

  test('the switch turned off at B reads off at A', () async {
    final pair = await _pair();
    await pair.a.domain.todoDao.updateFields(
      _outcomeId,
      timeboxed: true,
      now: _t0,
    );
    await pair.sync();

    pair.b.wall.advance();
    await pair.b.domain.todoDao.updateFields(
      _outcomeId,
      timeboxed: false,
      now: _t0.add(const Duration(minutes: 1)),
    );
    await pair.sync();

    expect((await _action(pair.a))!.timeboxed, isFalse);
    expect((await _action(pair.b))!.timeboxed, isFalse);
  });

  test('an estimate cleared at A while B switches on reads as not Timeboxed '
      'on both devices', () async {
    final pair = await _pair();

    // A clears the estimate — the limit goes with it.
    await pair.a.domain.todoDao.updateFields(
      _outcomeId,
      clearTimeEstimate: true,
      now: _t0,
    );
    // B turns the switch on, without knowing about A's clear.
    pair.b.wall.advance();
    await pair.b.domain.todoDao.updateFields(
      _outcomeId,
      timeboxed: true,
      now: _t0.add(const Duration(minutes: 1)),
    );
    await pair.sync();

    for (final device in [pair.a, pair.b]) {
      final merged = (await _action(device))!;
      expect(merged.timeEstimate, isNull,
          reason: 'the cleared estimate stays cleared');
      // The switch may well be on, but a limit with no estimate is no limit:
      // one rule, in one place, decides.
      expect(
        isTimeboxedAction(
          timeboxed: merged.timeboxed,
          timeEstimate: merged.timeEstimate,
        ),
        isFalse,
      );
    }
  });
}
