/// The names a device gives itself, on a real store.
///
/// The name is ordinary synced data under `device_name.<node id hex>`, so
/// these tests drive the real DAO on a real in-memory database and read the
/// rows back: what a peer would read is what is asserted here.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/user_constants.dart';
import 'package:jeeves/sync/device_names.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/hosted_capture.dart';

import '../test_helpers.dart';

const _userId = 'user-1';

/// The member id an enrolled device is given, in the 32-hex form a clock
/// carries.
const _memberHex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

/// A control character, spelled out so the source file stays plain text.
final String _nul = String.fromCharCode(0);

GtdDatabase _openDb({DomainOpCapture? capture}) => GtdDatabase(
      NativeDatabase.memory(),
      opCapture: capture ?? const NoopDomainOpCapture(),
    );

/// Simulates enrolment: the device is given a member id, and its writes are
/// clocked with that id instead of the device node id.
Future<void> _enrol(GtdDatabase db, String memberHex) => db.customStatement(
      'UPDATE device_clock_identity SET enrolled_member_id_hex = ? WHERE id = 1',
      [memberHex],
    );

Future<String> _deviceNodeId(GtdDatabase db) async =>
    (await readClockIdentity(db)).deviceNodeId;

/// Lets the event queue run until [condition] holds, or until it has had
/// plenty of turns to settle. A store's change notification reaches a
/// subscriber over the event queue, so a fixed number of turns is a guess and
/// a condition is a fact.
Future<void> _waitFor(bool Function() condition) async {
  for (var turn = 0; turn < 20 && !condition(); turn++) {
    await pumpEventQueue();
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  group('normaliseDeviceName', () {
    test('trims', () {
      expect(normaliseDeviceName('  Pixel 8  '), 'Pixel 8');
    });

    test('collapses whitespace runs and control characters to one space', () {
      expect(normaliseDeviceName('Pixel   8'), 'Pixel 8');
      expect(normaliseDeviceName('Pixel\n8'), 'Pixel 8');
      expect(normaliseDeviceName('Pixel\t8'), 'Pixel 8');
      expect(normaliseDeviceName('Pixel\r\n8'), 'Pixel 8');
      expect(normaliseDeviceName('Pixel${_nul}8'), 'Pixel 8');
    });

    test('cuts to 40 characters', () {
      expect(normaliseDeviceName('x' * 41), 'x' * 40);
      expect(normaliseDeviceName('x' * 40), 'x' * 40);
    });

    test('never cuts in the middle of a surrogate pair', () {
      final name = '${'x' * 39}\u{1F600}';
      final normalised = normaliseDeviceName(name);
      expect(normalised, '${'x' * 39}\u{1F600}');
      expect(normalised!.runes.length, 40);
    });

    test('rejects an empty name', () {
      expect(normaliseDeviceName(''), isNull);
      expect(normaliseDeviceName('   '), isNull);
      expect(normaliseDeviceName('\n\t '), isNull);
    });

    test('rejects a value that is not a string', () {
      expect(normaliseDeviceName(null), isNull);
      expect(normaliseDeviceName(42), isNull);
      expect(normaliseDeviceName(['Pixel 8']), isNull);
      expect(normaliseDeviceName({'name': 'Pixel 8'}), isNull);
    });
  });

  group('deviceNameKey', () {
    test('a dashed UUID and its hex form give the same key', () {
      const dashed = '01234567-89ab-cdef-0123-456789abcdef';
      final hex = memberIdToHex(dashed);
      expect(deviceNameKey(dashed), 'device_name.$hex');
      expect(deviceNameKey(hex), deviceNameKey(dashed));
    });

    test('a malformed id throws', () {
      expect(() => deviceNameKey('not-an-id'), throwsArgumentError);
      expect(() => deviceNameKey(''), throwsArgumentError);
      expect(() => deviceNameKey('0123456789abcdef'), throwsArgumentError);
    });
  });

  group('ensureOwnNames', () {
    late GtdDatabase db;
    late RecordingDomainOpCapture capture;
    late int platformReads;
    String? platformName;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      capture = RecordingDomainOpCapture();
      db = _openDb(capture: capture);
      platformReads = 0;
      platformName = 'Pixel 8';
    });
    tearDown(() => db.close());

    DeviceNames names() => DeviceNames(
          db: db,
          readPlatformName: () async {
            platformReads++;
            return platformName;
          },
        );

    test('writes the platform name under the device node id', () async {
      final nodeId = await _deviceNodeId(db);

      await names().ensureOwnNames(_userId);

      expect(
        await db.userPreferencesDao.get(_userId, deviceNameKey(nodeId)),
        jsonEncode('Pixel 8'),
      );
      expect(platformReads, 1);
    });

    test('a second ensure writes nothing', () async {
      await names().ensureOwnNames(_userId);
      capture.clear();

      await names().ensureOwnNames(_userId);

      expect(capture.recorded, isEmpty,
          reason: 'a name that is already there must not be written again');
      expect(platformReads, 1,
          reason: 'a device that has a name must not ask the platform again');
    });

    test(
        'after enrolment, ensure copies the existing name to the member id '
        'key and does not ask the platform again', () async {
      final nodeId = await _deviceNodeId(db);
      await db.userPreferencesDao.set(
        _userId,
        deviceNameKey(nodeId),
        jsonEncode('Pixel 8'),
      );
      await _enrol(db, _memberHex);
      platformReads = 0;

      await names().ensureOwnNames(_userId);

      expect(
        await db.userPreferencesDao.get(_userId, deviceNameKey(_memberHex)),
        jsonEncode('Pixel 8'),
      );
      expect(
        await db.userPreferencesDao.get(_userId, deviceNameKey(nodeId)),
        jsonEncode('Pixel 8'),
      );
      expect(platformReads, 0,
          reason: 'the name this device already has is the seed');
    });

    test('a name stored under the local user seeds the name for a new user',
        () async {
      final nodeId = await _deviceNodeId(db);
      await db.userPreferencesDao.set(
        kLocalUserId,
        deviceNameKey(nodeId),
        jsonEncode("Asha's Pixel"),
      );

      await names().ensureOwnNames('user-2');

      expect(
        await db.userPreferencesDao.get('user-2', deviceNameKey(nodeId)),
        jsonEncode("Asha's Pixel"),
      );
      expect(platformReads, 0,
          reason: 'a name this device already carries beats the platform');
    });

    test('no platform name and no stored name writes no row', () async {
      platformName = null;

      await names().ensureOwnNames(_userId);

      final rows = await db.customSelect('SELECT * FROM user_preferences').get();
      expect(rows, isEmpty);
    });

    test('a failure is logged, not thrown', () async {
      final closed = _openDb();
      await closed.close();

      await DeviceNames(
        db: closed,
        readPlatformName: () async => 'Pixel 8',
      ).ensureOwnNames(_userId);
    });
  });

  group('renameThisDevice', () {
    late GtdDatabase db;

    setUp(() {
      db = _openDb();
    });
    tearDown(() => db.close());

    DeviceNames names() =>
        DeviceNames(db: db, readPlatformName: () async => 'Pixel 8');

    test('writes every own id', () async {
      final nodeId = await _deviceNodeId(db);
      await _enrol(db, _memberHex);

      await names().renameThisDevice(_userId, '  My   Phone  ');

      expect(
        await db.userPreferencesDao.get(_userId, deviceNameKey(nodeId)),
        jsonEncode('My Phone'),
      );
      expect(
        await db.userPreferencesDao.get(_userId, deviceNameKey(_memberHex)),
        jsonEncode('My Phone'),
      );
    });

    test('rejects a name that is empty once normalised', () async {
      expect(() => names().renameThisDevice(_userId, '   '),
          throwsArgumentError);
    });
  });

  group('watchThisDeviceName', () {
    late GtdDatabase db;

    setUp(() {
      db = _openDb();
    });
    tearDown(() => db.close());

    DeviceNames names() =>
        DeviceNames(db: db, readPlatformName: () async => 'Pixel 8');

    test('emits the new name', () async {
      final emitted = <String?>[];
      final subscription =
          names().watchThisDeviceName(_userId).listen(emitted.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      await names().renameThisDevice(_userId, 'My Phone');
      await _waitFor(() => emitted.contains('My Phone'));

      expect(emitted.last, 'My Phone');
    });

    test('a value that is not valid JSON reads as no name', () async {
      final nodeId = await _deviceNodeId(db);
      await db.userPreferencesDao.set(_userId, deviceNameKey(nodeId), 'not json');

      final emitted = <String?>[];
      final subscription =
          names().watchThisDeviceName(_userId).listen(emitted.add);
      addTearDown(subscription.cancel);
      await _waitFor(() => emitted.isNotEmpty);

      expect(emitted.last, isNull);
    });
  });
}
