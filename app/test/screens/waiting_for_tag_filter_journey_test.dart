/// Journey for #889: the Waiting For page follows the sticky tag filter.
///
/// Real in-memory store, real `waitingListGroupedProvider`, real
/// `AppShell` drawer tag cloud and `ActiveFilterBar`. The store is staged in `setUp` (outside FakeAsync) and
/// the drift streams are advanced with fixed-duration pumps, per
/// docs/TESTING.md.
@TestOn('!browser')
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/screens/waiting_for/waiting_for_screen.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/outcome_row.dart';

import '../test_helpers.dart';

const _userId = 'test-user';

class _NoAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;
  @override
  Future<void> logout() async {}
}

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  Future<void> reEnterPlanning() async {}
}

/// Keeps the planning banner's infinite pulse from blocking pumpAndSettle.
class _NoBannerSettingsNotifier extends FocusSessionPlanningSettingsNotifier {
  @override
  FocusSessionPlanningSettings build() =>
      const FocusSessionPlanningSettings(bannerEnabled: false);
}

Future<void> _insertTag(GtdDatabase db, String id, String name, String type) =>
    db.tagDao.upsertTag(TagsCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      userId: const Value(_userId),
    ));

Future<void> _insertTodo(GtdDatabase db, String id, String title) {
  final now = DateTime.now();
  return db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

/// Live Drift watches run, so pump fixed durations, never `pumpAndSettle`
/// (docs/TESTING.md).
Future<void> _pumpFor(WidgetTester tester, [int steps = 4]) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _insertTag(db, 'ctx', 'errand', 'context');
    await _insertTag(db, 'alice', 'Alice', 'person');
    await _insertTag(db, 'bob', 'Bob', 'person');
    await _insertTodo(db, 'a', 'Send the contract');
    await _insertTodo(db, 'b', 'Return the drill');
    await db.tagDao.assignTag('a', 'alice', _userId);
    await db.tagDao.assignTag('a', 'ctx', _userId);
    await db.tagDao.assignTag('b', 'bob', _userId);
  });

  tearDown(() => db.close());

  testWidgets('selecting a tag narrows the page; Clear all restores it',
      (tester) async {
    final ctxTag =
        Tag(id: 'ctx', name: 'errand', type: 'context', userId: _userId);
    final router = GoRouter(
      initialLocation: '/waiting-for',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/waiting-for',
              builder: (_, _) => const WaitingForScreen(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authTokenProvider.overrideWith(() => _NoAuthNotifier()),
          // The shell's other list/count streams are not under test; left
          // real they start store reads inside FakeAsync (docs/TESTING.md).
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          nextProvider.overrideWith((_) => Stream.value([])),
          waitingForProvider.overrideWith((_) => Stream.value([])),
          somedayMaybeProvider.overrideWith((_) => Stream.value([])),
          projectTagsProvider.overrideWith((_) => Stream.value([])),
          contextTagsProvider.overrideWith((_) => Stream.value([ctxTag])),
          contextTagsWithCountProvider.overrideWith(
              (_) => Stream.value([TagWithCount(tag: ctxTag, count: 1)])),
          focusSessionPlanningSelectedTasksProvider
              .overrideWith((_) => Stream.value([])),
          focusSessionPlanningProvider
              .overrideWith(() => _MockFocusSessionPlanningNotifier()),
          focusSessionPlanningSettingsProvider
              .overrideWith(() => _NoBannerSettingsNotifier()),
          periodicReviewBannerEnabledProvider.overrideWith((_) => false),
          nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _pumpFor(tester, 5);

    expect(find.byType(OutcomeRow), findsNWidgets(2));
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('active_filter_clear_all')), findsNothing);

    // Select the tag through the drawer's tag cloud, as a user would.
    await tester.tap(find.byKey(appTitleBarLeadingKey));
    await _pumpFor(tester, 3);
    await tester.ensureVisible(find.byKey(const Key('tag_chip_ctx')));
    await _pumpFor(tester, 3);
    await tester.tap(find.byKey(const Key('tag_chip_ctx')));
    await _pumpFor(tester, 5);

    expect(find.byType(OutcomeRow), findsOneWidget);
    expect(find.text('Send the contract'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Return the drill'), findsNothing);
    expect(find.text('Bob'), findsNothing);

    // Dismiss the drawer by tapping its scrim, then clear from the page.
    await tester.tapAt(const Offset(780, 300));
    await _pumpFor(tester, 3);
    await tester.tap(find.byKey(const Key('active_filter_clear_all')));
    await _pumpFor(tester, 5);

    expect(find.byType(OutcomeRow), findsNWidgets(2));
    expect(find.text('Return the drill'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.byKey(const Key('active_filter_clear_all')), findsNothing);

    // Dispose in the real zone so drift's subscription cleanup can finish.
    await tester.pumpWidget(const SizedBox());
    // Disposing the shell closes drift's query stream, which schedules a
    // zero-duration timer on the fake clock; flush it before the binding
    // checks for pending timers.
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(pumpEventQueue);
    await tester.pump(const Duration(milliseconds: 10));
  });
}
