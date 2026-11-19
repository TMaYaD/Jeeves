/// The Settings tile that shows this device's name, and the dialog that
/// changes it.
///
/// A device's name is ordinary synced data under `device_name.<node id hex>`,
/// so what a peer would read is what this tile reads: these tests drive the
/// real DAO on a real in-memory store and read the row back.
///
/// **The id is never on screen.** A device that shows "Pixel 8" is what the
/// user asked for; a device that shows a 32-hex string has failed, and the
/// failure is invisible until someone reads the screen. So the last test here
/// is the one that matters most.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/user_constants.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/sync/device_names.dart';
import 'package:jeeves/sync/host/hosted_capture.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

/// The signed-in account the screen reads and writes under.
const _userId = 'user-1';

/// The member id an enrolled device is given, in the 32-hex form a clock
/// carries.
const _memberHex = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<bool> areNotificationsAllowed() async => true;

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

/// The signed-in account, held still for the test.
///
/// The real notifier answers "local" until an auth flow says otherwise; the
/// screen under test needs an account of its own, because the name is stored
/// under the user id and a name stored under one account is not a name under
/// another.
class _FixedUserId extends CurrentUserIdNotifier {
  _FixedUserId(this.userId);

  final String userId;

  @override
  String build() => userId;
}

/// What the test drove: the store and the id the device was born with.
class _Fixture {
  const _Fixture({required this.db, required this.nodeId});

  final GtdDatabase db;
  final String nodeId;
}

/// Pumps Settings over a real in-memory store.
///
/// [storedName] is the name the device already has, if any; [enrolled] gives
/// the device a member id, as enrolment would.
Future<_Fixture> _pumpSettings(
  WidgetTester tester,
  SessionGate gate, {
  String userId = kLocalUserId,
  String? storedName,
  bool enrolled = false,
}) async {
  // A viewport tall enough to inflate the whole list, so "the tile is not
  // there" cannot be confused with "the tile is below the fold".
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  sessionGateNotifier.value = gate;
  addTearDown(() => sessionGateNotifier.value = SessionGate.checking);

  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  // The store's own calls run in the real event loop. A widget test's fake
  // clock only moves when a frame is pumped, so anything the store answers on
  // a timer would never answer inside the test body.
  final nodeId = (await tester.runAsync(() async {
    final id = (await readClockIdentity(db)).deviceNodeId;
    if (enrolled) {
      await db.customStatement(
        'UPDATE device_clock_identity SET enrolled_member_id_hex = ? '
        'WHERE id = 1',
        [_memberHex],
      );
    }
    if (storedName != null) {
      await db.userPreferencesDao.set(
        userId,
        deviceNameKey(id),
        jsonEncode(storedName),
      );
    }
    return id;
  }))!;

  final container = ProviderContainer(
    overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(_StubNotificationService()),
      currentUserIdProvider.overrideWith(() => _FixedUserId(userId)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(syncedPreferencesProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  // The name arrives over a stream, so the first frames have no name to show.
  await _settle(tester);

  return _Fixture(db: db, nodeId: nodeId);
}

/// Lets the store's notifications reach the widget.
///
/// The name travels over a stream the store feeds from its own event loop, so
/// the test gives that loop a real turn and then lets the frames settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => pumpEventQueue());
  await tester.pumpAndSettle();
}

/// The text the tile shows.
///
/// A `ListTile` renders its title before its subtitle, so the last text in the
/// tile is the name.
String _tileSubtitle(WidgetTester tester) {
  final texts = find.descendant(
    of: find.byKey(const Key('device_name_tile')),
    matching: find.byType(Text),
  );
  return tester.widgetList<Text>(texts).last.data ?? '';
}

/// Opens the rename dialog.
Future<void> _openRenameDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('device_name_tile')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('device_name_field')), findsOneWidget);
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The About section reads the build number from the plugin channel, which
    // has no implementation under `flutter test`. Left unmocked it throws, and
    // Riverpod's retry of the failed provider leaves a timer pending when the
    // test ends.
    PackageInfo.setMockInitialValues(
      appName: 'Jeeves',
      packageName: 'loonyb.in.jeeves',
      version: '1.3.0-alpha.17',
      buildNumber: '412',
      buildSignature: '',
    );
  });

  group('Settings — this device', () {
    testWidgets('shows the stored name, in every session state',
        (tester) async {
      final states = [
        (gate: SessionGate.signedOut, userId: kLocalUserId, enrolled: false),
        (gate: SessionGate.signedInNotEnrolled, userId: _userId, enrolled: false),
        (gate: SessionGate.ready, userId: _userId, enrolled: true),
      ];

      for (final state in states) {
        await _pumpSettings(
          tester,
          state.gate,
          userId: state.userId,
          storedName: 'Asha\'s Pixel',
          enrolled: state.enrolled,
        );

        expect(find.byKey(const Key('device_name_tile')), findsOneWidget,
            reason: state.gate.name);
        expect(find.text('This device'), findsOneWidget,
            reason: state.gate.name);
        expect(_tileSubtitle(tester), 'Asha\'s Pixel',
            reason: state.gate.name);
      }
    });

    testWidgets('shows "Not named yet" when the device has no name',
        (tester) async {
      await _pumpSettings(tester, SessionGate.ready, userId: _userId);

      expect(find.byKey(const Key('device_name_tile')), findsOneWidget);
      expect(_tileSubtitle(tester), 'Not named yet');
    });

    testWidgets('a new name is stored and shown on the tile', (tester) async {
      final fixture = await _pumpSettings(
        tester,
        SessionGate.ready,
        userId: _userId,
        storedName: 'Asha\'s Pixel',
        enrolled: true,
      );

      await _openRenameDialog(tester);
      await tester.enterText(
        find.byKey(const Key('device_name_field')),
        'Work phone',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_name_save')));
      await _settle(tester);

      expect(find.byKey(const Key('device_name_field')), findsNothing,
          reason: 'the dialog closes when the name is saved');
      expect(_tileSubtitle(tester), 'Work phone');
      expect(
        await tester.runAsync(
          () => fixture.db.userPreferencesDao.get(
            _userId,
            deviceNameKey(fixture.nodeId),
          ),
        ),
        jsonEncode('Work phone'),
      );
    });

    testWidgets('Save is refused for an empty or an all-space name',
        (tester) async {
      await _pumpSettings(
        tester,
        SessionGate.ready,
        userId: _userId,
        storedName: 'Asha\'s Pixel',
      );

      await _openRenameDialog(tester);

      TextButton saveButton() =>
          tester.widget<TextButton>(find.byKey(const Key('device_name_save')));

      await tester.enterText(find.byKey(const Key('device_name_field')), '');
      await tester.pumpAndSettle();
      expect(saveButton().onPressed, isNull,
          reason: 'a name with no visible character is not a name');

      await tester.enterText(find.byKey(const Key('device_name_field')), '   ');
      await tester.pumpAndSettle();
      expect(saveButton().onPressed, isNull,
          reason: 'a name of spaces is not a name either');

      await tester.enterText(
        find.byKey(const Key('device_name_field')),
        'Work phone',
      );
      await tester.pumpAndSettle();
      expect(saveButton().onPressed, isNotNull);
    });

    testWidgets('the tile never shows the device node id', (tester) async {
      final fixture = await _pumpSettings(
        tester,
        SessionGate.ready,
        userId: _userId,
        storedName: 'Asha\'s Pixel',
        enrolled: true,
      );

      final tileText = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('device_name_tile')),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data ?? '')
          .join(' ');
      expect(tileText.contains(fixture.nodeId), isFalse);

      await _openRenameDialog(tester);
      final dialogText = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .join(' ');
      expect(dialogText.contains(fixture.nodeId), isFalse);
      expect(dialogText.contains(_memberHex), isFalse);
    });
  });
}
