/// The long Break settings reach the user's other devices (issue #911).
///
/// Two real devices (real domain store, real sync store, real DAOs, real merge)
/// joined by the in-memory relay plugin: the two settings travel as two
/// separate preferences, so a change to one never drops the other.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/sync/host/change.dart';

import '../harness/reduced_state.dart';
import 'host_harness.dart';

const String _userId = 'long-break-user';

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

  return _Pair(a, b, sync);
}

Future<String?> _value(HostDevice device, String key) =>
    device.domain.userPreferencesDao.get(_userId, key);

void main() {
  test('the long Break length set on A reaches B', () async {
    final pair = await _pair();
    await pair.a.domain.userPreferencesDao.set(
        _userId, kFocusLongBreakDurationMinutesPrefKey, '25');
    await pair.sync();

    expect(await _value(pair.b, kFocusLongBreakDurationMinutesPrefKey), '25');
    expect(await _value(pair.a, kFocusLongBreakDurationMinutesPrefKey), '25');
  });

  test('the number of Sprints before a long Break set on B reaches A',
      () async {
    final pair = await _pair();
    await pair.b.domain.userPreferencesDao.set(
        _userId, kFocusSprintsBeforeLongBreakPrefKey, '6');
    await pair.sync();

    expect(await _value(pair.a, kFocusSprintsBeforeLongBreakPrefKey), '6');
    expect(await _value(pair.b, kFocusSprintsBeforeLongBreakPrefKey), '6');
  });

  test('two devices that set different settings keep both', () async {
    final pair = await _pair();
    await pair.a.domain.userPreferencesDao.set(
        _userId, kFocusLongBreakDurationMinutesPrefKey, '20');
    await pair.b.domain.userPreferencesDao.set(
        _userId, kFocusSprintsBeforeLongBreakPrefKey, '3');
    await pair.sync();

    for (final device in [pair.a, pair.b]) {
      expect(await _value(device, kFocusLongBreakDurationMinutesPrefKey), '20');
      expect(await _value(device, kFocusSprintsBeforeLongBreakPrefKey), '3');
    }
    expect(await canonicalReducedState(pair.b.sync),
        await canonicalReducedState(pair.a.sync));
  });

  test('two devices that set the same setting converge on the later write',
      () async {
    final pair = await _pair();
    await pair.a.domain.userPreferencesDao.set(
        _userId, kFocusLongBreakDurationMinutesPrefKey, '25');
    await pair.sync();

    // B writes later, so B's write is the one that stands.
    pair.b.wall.advance(60000);
    await pair.b.domain.userPreferencesDao.set(
        _userId, kFocusLongBreakDurationMinutesPrefKey, '30');
    await pair.sync();

    expect(await _value(pair.a, kFocusLongBreakDurationMinutesPrefKey), '30');
    expect(await _value(pair.b, kFocusLongBreakDurationMinutesPrefKey), '30');
    expect(await canonicalReducedState(pair.b.sync),
        await canonicalReducedState(pair.a.sync));
  });
}
