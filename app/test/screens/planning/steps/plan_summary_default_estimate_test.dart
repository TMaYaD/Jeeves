/// Widget tests for the configurable default time estimate on [PlanSummaryStep]
/// (#463).
///
/// Selected Outcomes that carry no `timeEstimate` are counted at a configurable
/// default (10 min by default) in the capacity total, the multi-select preview,
/// and as a lighter-blue segment of the capacity bar. The default is never
/// written onto the Outcome — estimate-less cards look exactly as they do today.
///
/// The harness mirrors `plan_summary_multi_select_test.dart`: the three list
/// streams are overridden with single-value streams over an in-memory todo
/// source so the test does not subscribe to drift's `StreamQueryStore`. A real
/// [notificationServiceProvider] stub is supplied because watching the settings
/// provider now instantiates it (it reschedules the planning reminder on
/// synced-pref changes).
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/screens/planning/steps/plan_summary_step.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers.dart';

class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super.forTesting();

  @override
  Future<void> scheduleRitualReminder(RitualId ritual, TimeOfDay time) async {}

  @override
  Future<void> cancelRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelRecurringRitualReminder(RitualId ritual) async {}

  @override
  Future<void> snoozeRitualReminder(RitualId ritual, int minutes) async {}

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}

  @override
  Future<void> cancelReminder(int id) async {}

  @override
  Future<void> cancelAll() async {}
}

final _testTodosProvider = Provider<List<Todo>>((_) => const []);

Todo _todo({
  required String id,
  required String title,
  int? timeEstimate,
}) {
  final now = DateTime.now();
  return Todo(
    id: id,
    title: title,
    intent: 'next',
    clarified: true,
    createdAt: now,
    updatedAt: now,
    userId: 'local',
    timeEstimate: timeEstimate,
  );
}

/// Pumps the step inside a controllable container so tests can seed the default
/// estimate and drive selection through the real planning notifier.
Future<ProviderContainer> _pumpStep(
  WidgetTester tester,
  GtdDatabase db,
  List<Todo> todos, {
  int? defaultEstimate,
}) async {
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    notificationServiceProvider.overrideWithValue(_StubNotificationService()),
    _testTodosProvider.overrideWith((_) => todos),
    nextForFocusSessionPlanningProvider.overrideWith((ref) {
      final state = ref.watch(focusSessionPlanningProvider);
      final reviewed = {
        ...state.reviewedTaskIds,
        ...state.pendingSelectedTaskIds,
      };
      final all = ref.watch(_testTodosProvider);
      return Stream.value(
        all.where((t) => !reviewed.contains(t.id)).toList(),
      );
    }),
    focusSessionPlanningSelectedTasksProvider.overrideWith((ref) {
      final ids = ref.watch(
        focusSessionPlanningProvider.select((s) => s.pendingSelectedTaskIds),
      );
      final all = ref.watch(_testTodosProvider);
      final indexById = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      final ordered = all.where((t) => ids.contains(t.id)).toList()
        ..sort((a, b) => indexById[a.id]!.compareTo(indexById[b.id]!));
      return Stream.value(ordered);
    }),
    skippedNextForFocusSessionPlanningProvider.overrideWith((ref) {
      final state = ref.watch(focusSessionPlanningProvider);
      final skippedIds = state.reviewedTaskIds
          .where((id) => !state.pendingSelectedTaskIds.contains(id))
          .toSet();
      final all = ref.watch(_testTodosProvider);
      return Stream.value(
        all.where((t) => skippedIds.contains(t.id)).toList(),
      );
    }),
  ]);
  addTearDown(container.dispose);
  await container.read(syncedPreferencesProvider.future);
  if (defaultEstimate != null) {
    await container
        .read(focusSessionPlanningSettingsProvider.notifier)
        .setDefaultTimeEstimate(defaultEstimate);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: PlanSummaryStep())),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _select(ProviderContainer container, String id) {
  container.read(focusSessionPlanningProvider.notifier).selectTask(id);
}

Finder _cardWithTitle(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Card));

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PlanSummaryStep — default time estimate (#463)', () {
    late GtdDatabase db;

    setUp(() => db = GtdDatabase(NativeDatabase.memory()));
    tearDown(() async => db.close());

    testWidgets('an estimate-less selected Outcome contributes the default',
        (tester) async {
      final container = await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Loose end'),
      ]);

      _select(container, 't1');
      await tester.pumpAndSettle();

      expect(find.textContaining('1 task · 10m planned'), findsOneWidget);
    });

    testWidgets('mixed real + default sums both (real estimates unaffected)',
        (tester) async {
      final container = await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Real', timeEstimate: 30),
        _todo(id: 't2', title: 'Loose end'),
      ]);

      _select(container, 't1');
      _select(container, 't2');
      await tester.pumpAndSettle();

      expect(find.textContaining('2 tasks · 40m planned'), findsOneWidget);
    });

    testWidgets('multi-select preview counts an estimate-less row at the default',
        (tester) async {
      await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Loose end'),
      ]);

      await tester.longPress(_cardWithTitle('Loose end').first);
      await tester.pumpAndSettle();

      expect(find.text('+10m planned'), findsOneWidget);
    });

    testWidgets('a changed default flows through both folds', (tester) async {
      final container = await _pumpStep(
        tester,
        db,
        [
          _todo(id: 't1', title: 'Planned loose end'),
          _todo(id: 't2', title: 'Pending loose end'),
        ],
        defaultEstimate: 25,
      );

      // Capacity fold: selecting an estimate-less task counts 25.
      _select(container, 't1');
      await tester.pumpAndSettle();
      expect(find.textContaining('1 task · 25m planned'), findsOneWidget);

      // Preview fold: long-pressing the remaining pending estimate-less row.
      await tester.longPress(_cardWithTitle('Pending loose end').first);
      await tester.pumpAndSettle();
      expect(find.text('+25m planned'), findsOneWidget);
    });

    testWidgets(
        'capacity bar shows both segments for a mixed selection, status tone '
        'still driven by the combined ratio', (tester) async {
      final container = await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Real', timeEstimate: 30),
        _todo(id: 't2', title: 'Loose end'),
      ]);

      _select(container, 't1');
      _select(container, 't2');
      await tester.pumpAndSettle();

      final realSegment = find.byKey(const Key('capacity_real_segment'));
      final defaultSegment = find.byKey(const Key('capacity_default_segment'));
      expect(realSegment, findsOneWidget);
      expect(defaultSegment, findsOneWidget);

      // 40 / 480 is well under 0.8 → green status tone for the real segment,
      // lighter blue for the default-counted segment.
      expect(tester.widget<Container>(realSegment).color,
          equals(const Color(0xFF16A34A)));
      expect(tester.widget<Container>(defaultSegment).color,
          equals(const Color(0xFF93C5FD)));
    });

    testWidgets(
        'all-real selection renders no lighter segment (bar unchanged)',
        (tester) async {
      final container = await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Real', timeEstimate: 30),
      ]);

      _select(container, 't1');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('capacity_real_segment')), findsOneWidget);
      expect(
          find.byKey(const Key('capacity_default_segment')), findsNothing);
    });

    testWidgets('estimate-less cards render no timer chip, before and after undo',
        (tester) async {
      final container = await _pumpStep(tester, db, [
        _todo(id: 't1', title: 'Loose end'),
      ]);

      // Pending: no timer chip.
      expect(find.byIcon(Icons.timer_outlined), findsNothing);

      _select(container, 't1');
      await tester.pumpAndSettle();
      // Selected into Today's Plan: still no timer chip (default never became
      // a real estimate on the Outcome).
      expect(find.byIcon(Icons.timer_outlined), findsNothing);

      container
          .read(focusSessionPlanningProvider.notifier)
          .undoTaskReview('t1');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.timer_outlined), findsNothing);
    });
  });
}
