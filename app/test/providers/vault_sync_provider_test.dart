/// The vault plugin, and the device it runs on.
///
/// **One plugin at a time** (#914): the vault runs where the op log does not,
/// and the op log's arrival stops it. It reads the folder again while the app
/// is open, and it hands the host's changes back to the folder — including the
/// ones a failed write left behind.
///
/// Real stores, a real host, a real plugin. The only stand-in is the folder:
/// the system folder is reached through the platform, and a test needs a folder
/// it can make slow, or make fail.
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/providers/vault_sync_provider.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const String _userId = 'vault-user';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late ProviderContainer container;
  late GtdDatabase db;
  late SyncDatabase syncDb;
  late _FakeSetting setting;
  late _FakeFolder folder;

  setUp(() {
    // A signed-out device: the steady state the vault is offered in.
    sessionGateNotifier.value = SessionGate.signedOut;
    setting = _FakeSetting('folder-a');
    folder = _FakeFolder();
    syncDb = SyncDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      // The app's own store, with the app's own capture binding: a write
      // through the DAO is a change the host merges, exactly as in production.
      databaseProvider.overrideWith((ref) => db),
      syncDatabaseProvider.overrideWith((ref) async => syncDb),
      vaultFolderSettingProvider.overrideWithValue(setting),
      vaultFolderFactoryProvider.overrideWithValue((reference) => folder),
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

  test('a folder change keeps the new vault its cursor', () async {
    // The old vault's first scan is still running when the folder changes.
    final blocked = Completer<void>();
    folder.readGate = blocked;

    unawaited(container.read(vaultPluginProvider.future));
    await settle();
    expect(folder.outcomeListCalls, 1,
        reason: 'the old vault is still reading the folder');

    // The person picks another folder.
    setting.reference = 'folder-b';
    container.invalidate(vaultFolderProvider);
    await settle();

    blocked.complete();
    await settle();
    await settle();

    final host = await container.read(syncHostProvider.future);
    expect(await host.cursorOf('vault'), isNotNull,
        reason: 'the old vault finished cleaning up before the new one attached');
  });

  test('a first scan that fails leaves the host without the vault', () async {
    // An Outcome in the store: the first pass has a page to write.
    await db.todoDao.insertOutcome(
      id: 'outcome-1',
      title: 'Old title',
      userId: _userId,
    );
    await settle();
    folder.failWrites = true;

    await expectLater(
      container.read(vaultPluginProvider.future),
      throwsA(anything),
      reason: 'the first scan failed',
    );

    // The folder is writable again, and a new Outcome reaches the store: the
    // vault is not on the host, so nothing is delivered to it.
    folder.failWrites = false;
    await db.todoDao.insertOutcome(
      id: 'outcome-2',
      title: 'New title',
      userId: _userId,
    );
    await settle();
    await settle();

    expect(folder.pages, isEmpty,
        reason: 'the failed attachment was taken off the host');
  });

  testWidgets('the folder is read again once, however many times it is asked',
      (tester) async {
    await container.read(vaultPluginProvider.future);
    await _settle(tester);
    expect(folder.outcomeListCalls, 1, reason: 'the first pass read it once');

    // The app comes forward, and the read is slow.
    final blocked = Completer<void>();
    folder.readGate = blocked;
    for (var i = 0; i < 5; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    await _settle(tester);
    expect(folder.outcomeListCalls, 2,
        reason: 'one read is running, and the rest wait for it');

    blocked.complete();
    await _settle(tester);
    await _settle(tester);

    expect(folder.outcomeListCalls, 3,
        reason: 'the five asks were one running read and one waiting');
  });

  testWidgets('a page whose write failed is delivered once the folder is '
      'writable again', (tester) async {
    await container.read(vaultPluginProvider.future);
    await _settle(tester);

    // The folder cannot be written to: the host's delivery fails, and the
    // change stays owed.
    folder.failWrites = true;
    unawaited(db.todoDao.insertOutcome(
      id: 'outcome-1',
      title: 'Old title',
      userId: _userId,
    ));
    await _settle(tester);
    await _settle(tester);
    expect(folder.pages, isEmpty, reason: 'the page could not be written');

    // The folder is writable again, and the app comes forward.
    folder.failWrites = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    await _settle(tester);

    expect(
      folder.pages.keys.where((path) => path.startsWith('Outcomes/')),
      isNotEmpty,
      reason: 'the owed change was delivered after the folder came back',
    );
  });
}

/// Let the real work happen: real time for the file and database I/O, and the
/// test's clock pumped so the continuations that started in the test's own zone
/// run too.
Future<void> _settle(WidgetTester tester) async {
  await settleWithRealAsync(tester, rounds: 3);
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

/// A folder a test can make slow, and make fail.
class _FakeFolder implements VaultFolder {
  /// The pages the folder holds.
  final Map<String, String> pages = <String, String>{};

  /// Whether a write fails.
  bool failWrites = false;

  /// What a read waits for, when it is set.
  Completer<void>? readGate;

  /// How many times the Outcomes folder was listed: one per read of the
  /// folder.
  int outcomeListCalls = 0;

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async {
    if (subfolder == 'Outcomes') outcomeListCalls++;
    final gate = readGate;
    if (gate != null) await gate.future;
    return [
      for (final path in pages.keys)
        if (path.startsWith('$subfolder/')) path,
    ];
  }

  @override
  Future<String?> read(String relativePath) async => pages[relativePath];

  @override
  Future<void> writeAtomically(String relativePath, String text) async {
    if (failWrites) throw StateError('the folder is not writable');
    pages[relativePath] = text;
  }

  @override
  Future<void> remove(String relativePath) async {
    pages.remove(relativePath);
  }
}
