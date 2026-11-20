/// The vault's row in Settings: what it offers, and what it says.
///
/// The vault's whole setting is one string — this device's reference to the
/// folder — so the row has three states: the setting is still being read, the
/// setting says there is no folder, or the setting names a folder. The row
/// tells the truth about each, and every action it offers follows from the
/// setting rather than from what the screen happens to know yet.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/vault_sync_provider.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the vault runs where the op log does not', () {
    testWidgets('a device that has not enrolled is offered the folder',
        (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.signedInNotEnrolled,
        setting: _FakeSetting(),
        picker: _FakePicker(reference: '/tmp/vault'),
      );

      expect(find.byKey(const Key('vault_folder_tile')), findsOneWidget);
      expect(find.text('Sync through a folder of pages'), findsOneWidget);
    });

    testWidgets('an enrolled device is still offered the way to stop',
        (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.ready,
        setting: _FakeSetting('/tmp/vault'),
        picker: _FakePicker(),
      );

      expect(find.text('Stop syncing through this folder'), findsOneWidget);
    });
  });

  group('where there is no folder picker', () {
    testWidgets('there is no setup, but the folder can still be forgotten',
        (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: _FakeSetting(),
        picker: _FakePicker(),
        pickerAvailable: false,
      );

      expect(find.byKey(const Key('vault_folder_tile')), findsNothing);
      expect(find.text('Sync through a folder of pages'), findsNothing);

      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: _FakeSetting('/tmp/vault'),
        picker: _FakePicker(),
        pickerAvailable: false,
      );

      expect(find.text('Stop syncing through this folder'), findsOneWidget);
    });
  });

  group('the setting is not known yet', () {
    testWidgets('the enrolment ceremony waits for it', (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.signedInNotEnrolled,
        setting: _FakeSetting()..hangs = true,
        picker: _FakePicker(reference: '/tmp/vault'),
      );

      expect(find.byKey(const Key('enrolment_ceremony_tile')), findsNothing);
      expect(find.byKey(const Key('vault_folder_tile')), findsNothing);
      expect(find.byKey(const Key('vault_folder_loading_tile')), findsOneWidget);
    });
  });

  group('the setting that did not reach storage', () {
    testWidgets('is reported, and is not a successful toggle', (tester) async {
      final setting = _FakeSetting()..fails = true;
      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: setting,
        picker: _FakePicker(reference: '/tmp/vault'),
      );

      await tester.tap(find.byKey(const Key('vault_folder_tile')));
      await tester.pumpAndSettle();

      expect(find.text('The folder setting could not be saved. Try again.'),
          findsOneWidget);
      expect(find.text('Stop syncing through this folder'), findsNothing);
      expect(find.text('Sync through a folder of pages'), findsOneWidget);
    });
  });

  group('the folder picker', () {
    testWidgets('a failure is reported', (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: _FakeSetting(),
        picker: _FakePicker(failure: StateError('unavailable')),
      );

      await tester.tap(find.byKey(const Key('vault_folder_tile')));
      await tester.pumpAndSettle();

      expect(find.text('The folder picker could not be opened. Try again.'),
          findsOneWidget);
      expect(find.text('Stop syncing through this folder'), findsNothing);
    });

    testWidgets('a cancellation changes nothing', (tester) async {
      final setting = _FakeSetting();
      final picker = _FakePicker();
      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: setting,
        picker: picker,
      );

      await tester.tap(find.byKey(const Key('vault_folder_tile')));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(setting.reference, isNull);
      expect(find.text('Stop syncing through this folder'), findsNothing);
      expect(find.textContaining('could not'), findsNothing);
    });

    testWidgets('the action is off while it is open', (tester) async {
      await _pumpSettings(
        tester,
        gate: SessionGate.signedOut,
        setting: _FakeSetting(),
        picker: _FakePicker()..staysOpen = true,
      );

      await tester.tap(find.byKey(const Key('vault_folder_tile')));
      await tester.pump();

      final tile =
          tester.widget<ListTile>(find.byKey(const Key('vault_folder_tile')));
      expect(tile.onTap, isNull, reason: 'a second tap cannot reach the picker');
    });
  });
}

/// Pump the Settings screen with the vault's own pieces in a test's hands.
Future<void> _pumpSettings(
  WidgetTester tester, {
  required SessionGate gate,
  required _FakeSetting setting,
  required _FakePicker picker,
  bool pickerAvailable = true,
}) async {
  // A viewport tall enough to inflate the whole list, so "the row is not
  // there" cannot be confused with "the row is below the fold".
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  sessionGateNotifier.value = gate;
  addTearDown(() => sessionGateNotifier.value = SessionGate.checking);

  final db = GtdDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      vaultFolderSettingProvider.overrideWithValue(setting),
      vaultFolderPickerProvider.overrideWithValue(picker.call),
      vaultFolderPickerAvailableProvider.overrideWithValue(pickerAvailable),
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
  await tester.pumpAndSettle();
}

/// The vault's folder setting, in a test's hands.
class _FakeSetting implements VaultFolderSetting {
  _FakeSetting([this.reference]);

  String? reference;

  /// Whether the platform refuses the write.
  bool fails = false;

  /// Whether the read never answers.
  bool hangs = false;

  @override
  Future<String?> read() async {
    if (hangs) await Completer<String?>().future;
    return reference;
  }

  @override
  Future<bool> save(String reference) async {
    if (fails) return false;
    this.reference = reference;
    return true;
  }

  @override
  Future<bool> clear() async {
    if (fails) return false;
    reference = null;
    return true;
  }
}

/// The folder picker, in a test's hands.
class _FakePicker {
  _FakePicker({this.reference, this.failure});

  /// What the picker returns, or null when the person cancelled.
  String? reference;

  /// What the picker fails with, when it fails.
  Object? failure;

  /// Whether the picker is left open.
  bool staysOpen = false;

  /// How many times the picker was asked.
  int calls = 0;

  Future<String?> call() async {
    calls++;
    if (failure != null) throw failure!;
    if (staysOpen) await Completer<String?>().future;
    return reference;
  }
}
