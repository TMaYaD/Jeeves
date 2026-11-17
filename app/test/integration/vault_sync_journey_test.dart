/// The vault, through the app's own route.
///
/// Turn the vault on in Settings, create an Outcome in the app, find its page
/// in the folder, edit the page by hand, bring the app forward, and see the
/// edit on screen.
///
/// Real stores, a real folder on disk, the real Settings screen and the real
/// lifecycle. **The only stand-in is the folder picker**: it is a system
/// dialog, and a dialog cannot run headless, so a provider override returns
/// the folder instead. Everything else about the vault is the production path.
///
/// The harness follows the shape the other Settings journeys use: the stores
/// are opened outside the test's fake clock, the notification plugin is
/// stubbed, the time-boundary tick is pinned, and the work is settled by
/// bounded rounds rather than by waiting for the screen to go quiet (see
/// `docs/TESTING.md`).
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/providers/vault_sync_provider.dart';
import 'package:jeeves/screens/common/gtd_list_screen.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/settle.dart';
import '../test_helpers.dart';

const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _userId = 'vault-user';

void main() {
  setUpAll(configureSqliteForTests);

  late Directory vault;
  late ProviderContainer container;
  late GtdDatabase db;
  late SyncDatabase syncDb;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    vault = await Directory.systemTemp.createTemp('vault-sync-journey');
    // The vault's tile is offered to a device that has not enrolled for the op
    // log; a signed-out device is the steady state the vault is offered in.
    sessionGateNotifier.value = SessionGate.signedOut;

    // The stores are opened here, outside the test's fake clock: a store
    // opened inside a widget test cannot answer its first query.
    syncDb = SyncDatabase(NativeDatabase.memory());

    container = ProviderContainer(overrides: [
      // The app's own store, with the app's own capture binding: a write
      // through the DAO is a change the host merges, exactly as in production.
      databaseProvider.overrideWith((ref) => db),
      syncDatabaseProvider.overrideWith((ref) async => syncDb),
      // The Settings screen waits for the next time boundary, and the test's
      // clock is not the wall clock: the boundary would never come.
      nudgeBoundaryTickProvider.overrideWithValue(0),
      // The OS notification plugin is not there to be asked, and the row that
      // asks it is on the screen.
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      // The picker is a system dialog; the folder it would return is a path.
      vaultFolderPickerProvider.overrideWithValue(() async => vault.path),
    ]);
    // The capture the host drains is the same one the store writes through.
    db = GtdDatabase(
      NativeDatabase.memory(),
      opCapture: container.read(hostedDomainOpCaptureProvider),
    );
  });

  tearDown(() async {
    sessionGateNotifier.value = SessionGate.checking;
    await db.close();
    await syncDb.close();
    if (vault.existsSync()) await vault.delete(recursive: true);
  });

  testWidgets('a page edited by hand reaches the app when it comes forward', (
    tester,
  ) async {
    // The whole Settings list fits on the surface, so the vault's tile is on
    // the screen without a scroll.
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/', builder: (_, _) => GtdListScreen(provider: nextProvider)),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    try {
      await _settle(tester);

      // The vault is turned on from Settings, the way a person turns it on.
      final tile = find.byKey(const Key('vault_folder_tile'));
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await _settleUntil(
        tester,
        () => find.text('Stop syncing through this folder').evaluate().isNotEmpty,
      );
      expect(find.text('Stop syncing through this folder'), findsOneWidget);

      // The plugin attaches: the vault is running, not merely configured.
      Object? pluginError;
      var pluginAttached = false;
      unawaited(
        container.read(vaultPluginProvider.future).then(
          (plugin) => pluginAttached = plugin != null,
          onError: (Object error) => pluginError = error,
        ),
      );
      await _settleUntil(tester, () {
        final error = pluginError;
        if (error != null) fail('the vault plugin did not start: $error');
        return pluginAttached;
      });

      // An Outcome created in the app.
      //
      // The write is started here and not awaited: the app's write path waits
      // for the host's drain, and the drain waits for the store's own
      // watchers — continuations that run on the test's clock. Awaiting the
      // write would stop the clock it is waiting on. So the test keeps the
      // clock moving and watches the folder for the page the write produces.
      Object? writeError;
      var written = false;
      unawaited(
        db.todoDao
            .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId)
            .then(
              (_) => written = true,
              onError: (Object error) => writeError = error,
            ),
      );
      await _settleUntil(tester, () {
        final error = writeError;
        if (error != null) fail('the app write failed: $error');
        return written && _pagesIn(vault).isNotEmpty;
      });

      // Its page is in the folder.
      final path = _pagePath(vault);
      final page = File(path).readAsStringSync();
      expect(page, contains('title: Old title'));

      // The app is on the list, showing the Outcome.
      router.go('/');
      await _settle(tester);
      expect(find.text('Old title'), findsOneWidget);

      // A person edits the page in another tool.
      await tester.runAsync(
        () => File(path).writeAsString(
          page.replaceFirst('title: Old title', 'title: New title'),
        ),
      );

      // The app comes forward.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      // The edit reaches the app, and the app shows it.
      await _settleUntil(
        tester,
        () => find.text('New title').evaluate().isNotEmpty,
      );
      expect(find.text('New title'), findsOneWidget);
      expect(find.text('Old title'), findsNothing);

      // And the page says so too.
      expect(File(path).readAsStringSync(), contains('title: New title'));
    } finally {
      // The tree comes down first, so the watchers let go of the store, and the
      // container goes in the real zone, where the vault's own teardown can
      // finish.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async => container.dispose());
    }
  });
}

/// The pages in the vault's Outcomes folder.
List<String> _pagesIn(Directory vault) {
  final outcomes = Directory('${vault.path}/Outcomes');
  if (!outcomes.existsSync()) return const [];
  final pages = outcomes
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.md'))
      .map((file) => file.path)
      .toList();
  pages.sort();
  return pages;
}

/// The one page in the vault's Outcomes folder.
String _pagePath(Directory vault) {
  final files = _pagesIn(vault);
  expect(files, hasLength(1), reason: 'the Outcome has a page in the folder');
  return files.single;
}

/// Let the real work happen: real time for the file and database I/O, and the
/// test's clock pumped so the continuations that started in the test's own zone
/// run too.
Future<void> _settle(WidgetTester tester) async {
  await settleWithRealAsync(tester, rounds: 3);
}

/// The same, until [done] says the work is done.
///
/// [done] is asked in the test's own zone and answers from what the test can
/// see without touching the store: the widget tree, or the folder on disk.
Future<void> _settleUntil(WidgetTester tester, bool Function() done) async {
  for (var round = 0; round < 40; round++) {
    await settleWithRealAsync(tester, rounds: 1);
    if (done()) return;
  }
  fail('the vault did not settle in time');
}
