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
/// stubbed, the time-boundary tick is pinned, and the work is settled by real
/// time rather than by waiting for the screen to go quiet (see
/// `docs/TESTING.md`). The Next list is a live Drift watch, and a live watch
/// keeps `pumpAndSettle` spinning to its timeout, so the frames are pumped
/// one at a time — the way the other list journeys do it.
///
/// The journey runs twice: once against the folder as it is, and once against
/// a folder whose every operation takes real time. The slow half is the point
/// of the wait's shape — a wait that counted rounds instead of seconds gave a
/// busy machine less time than the work needed, and the journey failed at
/// random in CI.
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
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/vault/page_codec.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
import 'package:jeeves/sync/vault/vault_folder_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _userId = 'vault-user';

/// How long one wait may take in real time before it gives up.
///
/// **Real time, not a count of rounds.** The vault does real file I/O, and a
/// round of the old wait cost the test's own clock, not the wall clock the
/// files are slow on: forty of them were worth less than a second on a quick
/// machine, so a machine that stalled for a few hundred milliseconds ran the
/// budget out — and on a slow one they were worth ten seconds, so the same
/// test passed or failed with the machine's mood.
const Duration _waitDeadline = Duration(seconds: 30);

/// The real time the journey's waits may take together.
///
/// The suite's per-test budget is 60 seconds, and the waits must be able to
/// give up and say what they saw inside it.
const Duration _journeyRealBudget = Duration(seconds: 45);

/// The real time one step of a wait costs.
///
/// The wait spends its wall-clock budget here, so a round is worth real time
/// however quick the machine is: a wait that counted rounds gave a quick
/// machine less time than the work needed.
const Duration _stepRealTime = Duration(milliseconds: 5);

/// The fake clock's advance per step of a wait.
///
/// Small on purpose. The vault reads the folder again every 30 seconds of fake
/// time, and a wait that advanced the clock that fast would let that periodic
/// scan deliver the hand edit the resume path is meant to deliver — a broken
/// resume path would pass.
const Duration _stepFakeTime = Duration(milliseconds: 5);

/// The fake time the whole journey may spend, across every wait.
///
/// Below the vault's 30-second scan interval, so the periodic scan cannot
/// stand in for the resume path however long the journey takes.
const Duration _journeyFakeBudget = Duration(seconds: 10);

/// The delay every operation on the folder takes in the slow journey.
///
/// Real time, and four hundred milliseconds of it: the point is a folder that
/// is slow the way a busy machine or a slow disk makes it, not one that spends
/// the test's budget.
const Duration _slowFolderDelay = Duration(milliseconds: 400);

void main() {
  setUpAll(configureSqliteForTests);

  late Directory vault;
  late ProviderContainer container;
  late GtdDatabase db;
  late SyncDatabase syncDb;

  /// The delay every operation on the folder takes. Zero for the ordinary
  /// journey, real for the slow one.
  late Duration folderDelay;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    vault = await Directory.systemTemp.createTemp('vault-sync-journey');
    folderDelay = Duration.zero;
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
      // The folder the vault works through. The slow journey makes every
      // operation on it take real time.
      vaultFolderFactoryProvider.overrideWithValue(
        (reference) => _SlowFolder(openVaultFolder(reference), folderDelay),
      ),
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
    await _journey(tester, container: container, db: db, vault: vault);
  });

  testWidgets('the journey settles when every folder operation is slow', (
    tester,
  ) async {
    // The folder is slow the way a busy machine makes it: every operation on
    // it takes real time. The journey must still settle — a wait that counted
    // rounds rather than seconds did not.
    folderDelay = _slowFolderDelay;
    await _journey(tester, container: container, db: db, vault: vault);
  });
}

/// The journey, from the Settings screen to the edit on screen.
///
/// The vault is turned on, an Outcome is written and lands in the folder, the
/// page is edited by hand, and the app shows the edit when it comes forward.
Future<void> _journey(
  WidgetTester tester, {
  required ProviderContainer container,
  required GtdDatabase db,
  required Directory vault,
}) async {
  final clock = _JourneyClock();

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
    await _settle(tester, clock);

    // The vault is turned on from Settings, the way a person turns it on.
    final tile = find.byKey(const Key('vault_folder_tile'));
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await _settleUntil(
      tester,
      clock,
      () => find.text('Stop syncing through this folder').evaluate().isNotEmpty,
      what: 'the vault to offer to stop syncing',
      describe: () => _snapshot(tester, vault),
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
    await _settleUntil(tester, clock, () {
      final error = pluginError;
      if (error != null) fail('the vault plugin did not start: $error');
      return pluginAttached;
    }, what: 'the vault plugin to attach', describe: () => _snapshot(tester, vault));

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
    await _settleUntil(tester, clock, () {
      final error = writeError;
      if (error != null) fail('the app write failed: $error');
      return written && _pagesIn(vault).isNotEmpty;
    }, what: 'the app write to land in the folder', describe: () => _snapshot(tester, vault));

    // Its page is in the folder.
    final path = _pagePath(vault);
    final page = File(path).readAsStringSync();
    expect(page, contains('title: Old title'));

    // The block says what the app wrote: the title's digest, at the clock
    // that write stamped.
    final writtenTitle = _titleEntry(page);
    expect(writtenTitle, isNotNull,
        reason: 'the page carries the title in its block');
    final writtenEntry = writtenTitle!;
    expect(writtenEntry.digest, digestOf('Old title'));

    // The app is on the list, showing the Outcome.
    router.go('/');
    await _settle(tester, clock);
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
      clock,
      () => find.text('New title').evaluate().isNotEmpty,
      what: 'the hand edit to reach the app',
      describe: () => _snapshot(tester, vault),
    );
    expect(find.text('New title'), findsOneWidget);
    expect(find.text('Old title'), findsNothing);

    // And the host wrote the merged page back: the block carries the new
    // title's digest, at a clock of its own. The page's frontmatter alone
    // would not say so — the hand edit put that there.
    await _settleUntil(tester, clock, () {
      final entry = _titleEntry(File(path).readAsStringSync());
      return entry != null && entry.digest == digestOf('New title');
    }, what: 'the host to write the merged page back', describe: () => _snapshot(tester, vault));
    final rewritten = _titleEntry(File(path).readAsStringSync());
    expect(rewritten, isNotNull,
        reason: 'the page still carries the title in its block');
    final rewrittenEntry = rewritten!;
    expect(rewrittenEntry.digest, digestOf('New title'),
        reason: 'the host wrote the merged page back');
    expect(rewrittenEntry.hlc, isNot(writtenEntry.hlc),
        reason: 'the hand edit carries a clock of its own');
  } finally {
    // The tree comes down first, so the watchers let go of the store, and the
    // container goes in the real zone, where the vault's own teardown can
    // finish.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async => container.dispose());
  }
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
///
/// The frames are pumped one at a time, never through `pumpAndSettle`: the
/// Next list is a live Drift watch, and a live watch keeps the settle from
/// ever going quiet. This is the shape the other list journeys use
/// (`outcome_row_journey_test.dart`).
Future<void> _settle(WidgetTester tester, _JourneyClock clock) async {
  for (var i = 0; i < 6; i++) {
    await _step(tester, clock, const Duration(milliseconds: 150));
  }
}

/// One step of a wait: real time passes, then the test's own clock moves.
///
/// The real time is what the work needs — the files are real files — and the
/// clock's advance is what lets the continuations the real work started in the
/// test's own zone run.
Future<void> _step(
  WidgetTester tester,
  _JourneyClock clock, [
  Duration fakeTime = _stepFakeTime,
]) async {
  await tester.runAsync(() async {
    // Real time: the timer is the root zone's, so it is the machine's clock
    // and not the test's.
    await Zone.root.run(() => Future<void>.delayed(_stepRealTime));
    await pumpEventQueue();
  });
  await tester.pump(clock.advance(fakeTime));
}

/// The same, until [done] says the work is done.
///
/// [done] is asked in the test's own zone and answers from what the test can
/// see without touching the store: the widget tree, or the folder on disk.
///
/// **The budget is real time.** A wait that counted rounds measured the test's
/// own clock, not the wall clock the files are slow on, and the vault's file
/// I/O is real: forty rounds were worth less than a second, so a machine that
/// stalled for a few hundred milliseconds ran the budget out and the journey
/// failed at random. When the budget runs out, the wait says what it saw.
Future<void> _settleUntil(
  WidgetTester tester,
  _JourneyClock clock,
  bool Function() done, {
  required String what,
  required String Function() describe,
}) async {
  final started = DateTime.now();
  var rounds = 0;
  while (DateTime.now().difference(started) < _waitDeadline &&
      !clock.outOfTime) {
    await _step(tester, clock);
    await _step(tester, clock);
    rounds++;
    if (done()) return;
  }
  fail('the vault did not settle in time: $what\n'
      'after $rounds rounds, '
      '${DateTime.now().difference(started).inMilliseconds} ms of real time and '
      '${clock.spent.inMilliseconds} ms of the test\'s clock\n'
      '${describe()}');
}

/// The journey's clock.
///
/// The fake time is the journey's, not a wait's: the vault's periodic scan
/// runs for the whole test, so the budget that keeps that scan from firing is
/// the whole test's. So is the real time: the waits together must be able to
/// give up inside the suite's per-test budget.
class _JourneyClock {
  _JourneyClock() : _started = DateTime.now();

  final DateTime _started;
  Duration _spent = Duration.zero;

  /// The fake time the journey has spent.
  Duration get spent => _spent;

  /// Whether the journey's waits have spent their real-time budget.
  bool get outOfTime =>
      DateTime.now().difference(_started) >= _journeyRealBudget;

  /// The fake time the next step may advance the clock by.
  ///
  /// Zero once the journey has spent its budget: the steps keep coming, so
  /// the real work still gets its turns, but the clock stops moving and the
  /// vault's 30-second scan cannot come round.
  Duration advance([Duration step = _stepFakeTime]) {
    if (_spent >= _journeyFakeBudget) return Duration.zero;
    final left = _journeyFakeBudget - _spent;
    final take = step > left ? left : step;
    _spent += take;
    return take;
  }
}

/// A folder whose every operation takes real time.
///
/// The delay is the root zone's, so it is the machine's clock and not the
/// test's: a slow folder is a slow disk, and the wait must give it the
/// seconds it takes.
class _SlowFolder implements VaultFolder {
  _SlowFolder(this._inner, this._delay);

  final VaultFolder _inner;
  final Duration _delay;

  Future<void> _slow() async {
    if (_delay <= Duration.zero) return;
    await Zone.root.run(() => Future<void>.delayed(_delay));
  }

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) async {
    await _slow();
    return _inner.listMarkdownFiles(subfolder);
  }

  @override
  Future<String?> read(String relativePath) async {
    await _slow();
    return _inner.read(relativePath);
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) async {
    await _slow();
    await _inner.writeAtomically(relativePath, text);
  }

  @override
  Future<void> remove(String relativePath) async {
    await _slow();
    await _inner.remove(relativePath);
  }
}

/// What the wait could see when it gave up: the folder's pages, and what the
/// screen shows.
String _snapshot(WidgetTester tester, Directory vault) {
  final pages = _pagesIn(vault);
  final titles = <String>[];
  for (final path in pages) {
    final page = File(path).readAsStringSync();
    final line = page
        .split('\n')
        .firstWhere((line) => line.startsWith('title:'), orElse: () => 'no title');
    titles.add(line.trim());
  }
  return 'the folder holds ${pages.length} page(s) (${titles.join(', ')}); '
      'the screen shows "Old title": '
      '${find.text('Old title').evaluate().isNotEmpty}; '
      'the screen shows "New title": '
      '${find.text('New title').evaluate().isNotEmpty}';
}

/// The block's entry for the Outcome's title, or null when the page carries
/// no block, or no title in it.
BlockEntry? _titleEntry(String page) {
  final block = parsePage(page).block;
  if (block == null) return null;
  for (final entry in block) {
    if (entry.collection == todosCollection &&
        entry.entityId == _outcomeId &&
        entry.field == 'title') {
      return entry;
    }
  }
  return null;
}
