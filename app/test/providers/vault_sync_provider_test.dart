/// The vault plugin, and the device it runs on.
///
/// **One plugin at a time** (#914): the vault runs where the op log does not,
/// and the op log's arrival stops it.
///
/// Real stores, a real host, a real plugin. The only stand-in is the folder:
/// the system folder is reached through the platform, and a test needs a folder
/// it can make slow, or make fail.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/providers/vault_sync_provider.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late ProviderContainer container;
  late GtdDatabase db;
  late SyncDatabase syncDb;
  late _FakeSetting setting;
  late Directory vault;

  setUp(() async {
    // A signed-out device: the steady state the vault is offered in.
    sessionGateNotifier.value = SessionGate.signedOut;
    vault = await Directory.systemTemp.createTemp('vault-provider');
    setting = _FakeSetting(vault.path);
    syncDb = SyncDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      // The app's own store, with the app's own capture binding: a write
      // through the DAO is a change the host merges, exactly as in production.
      databaseProvider.overrideWith((ref) => db),
      syncDatabaseProvider.overrideWith((ref) async => syncDb),
      vaultFolderSettingProvider.overrideWithValue(setting),
    ]);
    db = GtdDatabase(
      NativeDatabase.memory(),
      opCapture: container.read(hostedDomainOpCaptureProvider),
    );
  });

  tearDown(() async {
    sessionGateNotifier.value = SessionGate.checking;
    container.dispose();
    await db.close();
    await syncDb.close();
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  /// Let the real work happen: the providers that rebuild, and the event queue
  /// the real work runs on.
  Future<void> settle() async {
    await container.pump();
    await pumpEventQueue(duration: const Duration(milliseconds: 20), times: 5);
  }

  group('the vault runs where the op log does not', () {
    test('a device that has not enrolled runs the vault', () async {
      sessionGateNotifier.value = SessionGate.signedInNotEnrolled;

      final plugin = await container.read(vaultPluginProvider.future);

      expect(plugin, isNotNull);
      final host = await container.read(syncHostProvider.future);
      expect(await host.cursorOf('vault'), isNotNull,
          reason: 'the vault is attached to the host');
    });

    test('an enrolled device does not run the vault', () async {
      sessionGateNotifier.value = SessionGate.ready;

      expect(await container.read(vaultPluginProvider.future), isNull);
      final host = await container.read(syncHostProvider.future);
      expect(await host.cursorOf('vault'), isNull,
          reason: 'the op log runs; the vault does not');
    });

    test('the op log arriving stops the vault', () async {
      sessionGateNotifier.value = SessionGate.signedInNotEnrolled;
      await container.read(vaultPluginProvider.future);
      final host = await container.read(syncHostProvider.future);
      expect(await host.cursorOf('vault'), isNotNull);

      // The account signs back in, and this device is enrolled.
      sessionGateNotifier.value = SessionGate.ready;
      await settle();

      expect(await host.cursorOf('vault'), isNull,
          reason: 'the vault let the host go when the op log took over');
    });
  });
}

/// The vault's folder setting, in a test's hands.
class _FakeSetting implements VaultFolderSetting {
  _FakeSetting(this.reference);

  String? reference;

  @override
  Future<String?> read() async => reference;

  @override
  Future<bool> save(String reference) async {
    this.reference = reference;
    return true;
  }

  @override
  Future<bool> clear() async {
    reference = null;
    return true;
  }
}
