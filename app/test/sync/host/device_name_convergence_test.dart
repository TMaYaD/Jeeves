/// A Device's name converges between two devices through the sync host.
///
/// Two real devices (real domain store, real sync store, real DAOs, real merge)
/// joined by the in-memory relay plugin: the merge rule is tested at the
/// sync-host level, so no concrete plugin is needed.
///
/// The name is ordinary synced data — one `user_preferences` row under
/// `device_name.<device id>` — so it merges like every other preference:
/// last write wins, and two devices that write it while apart end on the same
/// value.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/device_names.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/host/hosted_capture.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import '../harness/reduced_state.dart';
import 'host_harness.dart';

const String _userId = 'device-name-user';

/// The name A's platform would give it, and B's.
const String _platformNameA = 'A phone';
const String _platformNameB = 'B phone';

/// Two devices, one relay, and the names they give themselves.
class _Pair {
  _Pair({
    required this.a,
    required this.b,
    required this.hostA,
    required this.hostB,
    required this.pluginB,
    required this.namesA,
    required this.namesB,
    required this.aNodeId,
    required this.bNodeId,
    required this.sync,
  });

  final HostDevice a;
  final HostDevice b;
  final SyncHostService hostA;
  final SyncHostService hostB;
  final RelayPlugin pluginB;
  final DeviceNames namesA;
  final DeviceNames namesB;

  /// The device node id each device was born with — the id a peer sees on a
  /// change, and the id a name is stored under.
  final String aNodeId;
  final String bNodeId;

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

  final aNodeId = (await readClockIdentity(a.domain)).deviceNodeId;
  final bNodeId = (await readClockIdentity(b.domain)).deviceNodeId;

  // The applied-Grant check lives in the op-log client, not in the sync host,
  // so at this level there is no control log to consult. A is therefore taken
  // as a verified peer of B: the point of these tests is that the *name*
  // converges, and the verification that gates showing it is proved over the
  // op log in the step that has one.
  final namesA = DeviceNames(
    db: a.domain,
    readPlatformName: () async => _platformNameA,
    isVerifiedDevice: (hex) async => hex == bNodeId,
  );
  final namesB = DeviceNames(
    db: b.domain,
    readPlatformName: () async => _platformNameB,
    isVerifiedDevice: (hex) async => hex == aNodeId,
  );

  return _Pair(
    a: a,
    b: b,
    hostA: hostA,
    hostB: hostB,
    pluginB: pluginB,
    namesA: namesA,
    namesB: namesB,
    aNodeId: aNodeId,
    bNodeId: bNodeId,
    sync: sync,
  );
}

/// The stored value of A's name key on [device].
Future<String?> _storedA(HostDevice device, String aNodeId) =>
    device.domain.userPreferencesDao.get(_userId, deviceNameKey(aNodeId));

void main() {
  test("A's ensured name is readable on B after a relay round", () async {
    final pair = await _pair();
    await pair.namesA.ensureOwnNames(_userId);
    await pair.sync();

    expect(await _storedA(pair.b, pair.aNodeId), jsonEncode(_platformNameA),
        reason: 'the name crossed to B as ordinary synced preference data');
    expect(await pair.namesB.nameOf(_userId, pair.aNodeId), _platformNameA,
        reason: 'and B reads it back as a name');
  });

  test('A renames; after a round B reads the new name', () async {
    final pair = await _pair();
    await pair.namesA.ensureOwnNames(_userId);
    await pair.sync();

    await pair.namesA.renameThisDevice(_userId, 'Kitchen phone');
    await pair.sync();

    expect(await pair.namesB.nameOf(_userId, pair.aNodeId), 'Kitchen phone');
  });

  test('A renames twice while B does not pull; B then pulls once and reads the '
      'latest name', () async {
    final pair = await _pair();
    await pair.namesA.ensureOwnNames(_userId);
    await pair.sync();

    await pair.namesA.renameThisDevice(_userId, 'First rename');
    pair.a.wall.advance();
    await pair.namesA.renameThisDevice(_userId, 'Second rename');
    // Both renames reach the relay; B has pulled nothing since the ensure.
    await pair.hostA.deliverAll();

    await pair.pluginB.pull();
    await pair.hostB.deliverAll();

    expect(await pair.namesB.nameOf(_userId, pair.aNodeId), 'Second rename',
        reason: 'the later rename wins on the one pull');
  });

  test('A and B write A\'s key at different times; both end on the later write',
      () async {
    final pair = await _pair();
    final key = deviceNameKey(pair.aNodeId);

    pair.a.wall.advance(1000);
    await pair.a.domain.userPreferencesDao.set(_userId, key, jsonEncode('From A'));
    pair.b.wall.advance(5000);
    await pair.b.domain.userPreferencesDao.set(_userId, key, jsonEncode('From B'));
    await pair.sync();

    expect(await _storedA(pair.a, pair.aNodeId), jsonEncode('From B'),
        reason: 'the later write reaches A');
    expect(await _storedA(pair.b, pair.aNodeId), jsonEncode('From B'),
        reason: 'and B keeps its own');
    expect(await canonicalReducedState(pair.b.sync),
        await canonicalReducedState(pair.a.sync),
        reason: 'both devices hold the same merge state');
  });

  test('A and B write A\'s key at the same time; both end on the same value',
      () async {
    final pair = await _pair();
    final key = deviceNameKey(pair.aNodeId);

    // The same instant on both clocks, so the tie is broken by the device node
    // id — the same rule everywhere else in the merge.
    pair.a.wall.advance(1000);
    pair.b.wall.advance(1000);
    await pair.a.domain.userPreferencesDao.set(_userId, key, jsonEncode('From A'));
    await pair.b.domain.userPreferencesDao.set(_userId, key, jsonEncode('From B'));
    await pair.sync();

    final onA = await _storedA(pair.a, pair.aNodeId);
    final onB = await _storedA(pair.b, pair.aNodeId);
    expect(onA, onB, reason: 'the two devices end on one value');
    final winner =
        pair.aNodeId.compareTo(pair.bNodeId) > 0 ? 'From A' : 'From B';
    expect(onA, jsonEncode(winner),
        reason: 'and it is the one the greater device node id wrote');
    expect(await canonicalReducedState(pair.b.sync),
        await canonicalReducedState(pair.a.sync),
        reason: 'both devices hold the same merge state');
  });
}
