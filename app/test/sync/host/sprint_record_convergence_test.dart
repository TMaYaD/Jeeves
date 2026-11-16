/// Sprints recorded on one device show on the other, and their ends converge.
///
/// Two real devices (real domain store, real sync store, real DAOs, real merge)
/// joined by the in-memory relay plugin: the merge rule is tested at the sync-host
/// level, so no concrete plugin is needed (issue #910).
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/sprint_dao.dart';
import 'package:jeeves/sync/host/change.dart';

import '../harness/reduced_state.dart';
import 'host_harness.dart';

const String _userId = 'sprint-user';
const String _outcomeId = '5b4f3e6a-7c8d-4eaf-9012-3c4d5e6f7081';

final DateTime _t0 = DateTime.utc(2026, 7, 28, 9);

class _Pair {
  _Pair(this.a, this.b, this.sync);
  final HostDevice a;
  final HostDevice b;
  final Future<void> Function() sync;
}

Future<_Pair> _pair() async {
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

  await a.domain.todoDao
      .insertOutcome(id: _outcomeId, title: 'Write', userId: _userId);
  await sync();
  return _Pair(a, b, sync);
}

Future<String> _start(HostDevice device, DateTime at) =>
    device.domain.sprintDao.startSprint(
      taskId: _outcomeId,
      userId: _userId,
      plannedDurationMinutes: 25,
      now: at,
    );

Future<List<SprintRecord>> _records(HostDevice device) =>
    device.domain.sprintDao.getAllRecords();

void main() {
  test('a Sprint completed on A shows on B with the same start and end',
      () async {
    final pair = await _pair();
    await _start(pair.a, _t0);
    pair.a.wall.advance();
    await pair.a.domain.sprintDao
        .endRunningSprint(userId: _userId, now: _t0.add(const Duration(minutes: 25)));
    await pair.sync();

    final onB = await _records(pair.b);
    expect(onB, hasLength(1));
    expect(onB.single.startedAtUtc, _t0);
    expect(onB.single.endedAtUtc, _t0.add(const Duration(minutes: 25)));
    expect(onB.single.plannedDurationMinutes, 25);
    expect(onB.single.actionId, isNotNull);
  });

  test('a Sprint running on A shows as running on B', () async {
    final pair = await _pair();
    await _start(pair.a, _t0);
    await pair.sync();

    final onB = await _records(pair.b);
    expect(onB, hasLength(1));
    expect(onB.single.isRunning, isTrue);
  });

  for (final laterCloserIsA in [true, false]) {
    test(
        'two devices that closed one Sprint at different times converge on the '
        'earlier end (${laterCloserIsA ? "A" : "B"} holds the later clock)',
        () async {
      final pair = await _pair();
      await _start(pair.a, _t0);
      await pair.sync();

      final early = _t0.add(const Duration(minutes: 20));
      final late = _t0.add(const Duration(minutes: 30));
      // Whichever device writes last holds the later HLC; the earlier *end* must
      // win regardless of which clock is later.
      final first = laterCloserIsA ? pair.b : pair.a;
      final second = laterCloserIsA ? pair.a : pair.b;
      first.wall.advance();
      await first.domain.sprintDao.endRunningSprint(userId: _userId, now: early);
      second.wall.advance(60000);
      await second.domain.sprintDao.endRunningSprint(userId: _userId, now: late);
      await pair.sync();

      expect((await _records(pair.a)).single.endedAtUtc, early);
      expect((await _records(pair.b)).single.endedAtUtc, early);
      expect(await canonicalReducedState(pair.b.sync),
          await canonicalReducedState(pair.a.sync));
    });
  }

  test(
      'two devices that both left a Sprint open converge on an end just before '
      'the later Sprint, derived and never written', () async {
    final pair = await _pair();
    final firstId = await _start(pair.a, _t0);
    final later = _t0.add(const Duration(minutes: 10));
    pair.b.wall.advance();
    await _start(pair.b, later); // B has not seen A's Sprint yet.
    await pair.sync();

    final expectedEnd = later.subtract(const Duration(milliseconds: 1));
    for (final device in [pair.a, pair.b]) {
      final records = await _records(device);
      expect(records, hasLength(2));
      final first = records.firstWhere((r) => r.id == firstId);
      expect(first.endedAtUtc, expectedEnd);
      expect(first.storedEndedAtUtc, isNull,
          reason: 'the derived end is never written');
      expect(records.last.isRunning, isTrue);
    }
    expect(await canonicalReducedState(pair.b.sync),
        await canonicalReducedState(pair.a.sync));
  });
}
