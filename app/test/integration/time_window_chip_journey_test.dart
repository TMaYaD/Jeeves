/// Choosing a named time window on an Action (issue #55), over the real
/// stores.
///
/// The Time context chip offers the user's named windows beside the one-time
/// Time context. Picking a window attaches it; switching to one time clears
/// it; and a write is dropped when the current Action changed while the sheet
/// was open.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_peek_sheet.dart';
import 'package:jeeves/widgets/time_context_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

final _workHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 17 * 60),
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async {
  final result = await tester.runAsync(body);
  return result as T;
}

Future<void> _seedOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db, outcomeId: id, text: 'work on it', userId: _userId);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late String windowId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await _seedOutcome(db, 'o1');
    final id = await db.timeWindowDao.createTimeWindow(
      name: 'Work hours',
      hours: _workHours,
      userId: _userId,
    );
    expect(id, isNotNull);
    windowId = id!;
    container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    addTearDown(container.dispose);
  });

  tearDown(() async => db.close());

  Widget harness({String location = '/task/o1'}) {
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/task/:id',
          builder: (_, state) =>
              TaskDetailScreen(todoId: state.pathParameters['id']!),
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> openChip(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('time_context_chip')));
    await _settle(tester);
  }

  testWidgets('Outcome detail: pick a window, then switch to a one-time time',
      (tester) async {
    await tester.pumpWidget(harness());
    await _settle(tester);

    await openChip(tester);
    // The sheet offers the user's windows beside the one-time time.
    await tester.tap(find.byKey(const Key('time_context_choice_window')));
    await tester.pumpAndSettle();
    expect(find.text('Work hours'), findsOneWidget);
    expect(find.text('Mon–Fri 09:00–17:00'), findsOneWidget);

    await tester.tap(find.byKey(Key('time_context_window_$windowId')));
    await _settle(tester);

    // The chip reads the window's name.
    expect(find.text('Work hours'), findsOneWidget);
    final action = await _real(
        tester, () => db.select(db.actions).getSingle());
    expect(action.timeWindowId, windowId);

    // Switch to a one-time time: the window goes.
    await openChip(tester);
    await tester.tap(find.byKey(const Key('time_context_choice_one_time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('time_context_from')));
    await _settle(tester);
    await tester.tap(find.text('OK'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('time_context_save')));
    await _settle(tester);

    final after = await _real(tester, () => db.select(db.actions).getSingle());
    expect(after.timeWindowId, isNull);
    expect(after.timeContext, isNotNull);
    expect(find.text('Work hours'), findsNothing);
  });

  testWidgets('the Daily Planning peek offers the same windows', (tester) async {
    final todo = (await db.todoDao.getTodo('o1'))!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => OutcomePeekSheet.show(context, todo),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);

    await openChip(tester);
    await tester.tap(find.byKey(const Key('time_context_choice_window')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('time_context_window_$windowId')));
    await _settle(tester);

    final action = await _real(
        tester, () => db.select(db.actions).getSingle());
    expect(action.timeWindowId, windowId);
  });

  testWidgets('a write is dropped when the current Action changed while the '
      'sheet was open', (tester) async {
    await tester.pumpWidget(harness());
    await _settle(tester);

    await openChip(tester);
    await tester.tap(find.byKey(const Key('time_context_choice_window')));
    await tester.pumpAndSettle();

    // The Action is replaced while the sheet is open.
    await _real(tester, () async {
      await db.customStatement(
          "UPDATE actions SET role = 'superseded' WHERE outcome_id = 'o1'");
      await db.into(db.actions).insert(ActionsCompanion(
            id: const Value('a2'),
            outcomeId: const Value('o1'),
            userId: const Value(_userId),
            actionText: const Value('something else'),
            role: const Value('current'),
            createdAt: Value(DateTime.now()),
          ));
    });
    final successor = await _real(tester, () => db.select(db.actions).get());
    expect(successor, hasLength(2));

    await tester.tap(find.byKey(Key('time_context_window_$windowId')));
    await _settle(tester);

    // The successor carries no window: the edit never landed on an Action the
    // user did not see.
    final rows = await _real(tester, () => db.select(db.actions).get());
    expect(
      rows.where((a) => a.timeWindowId != null),
      isEmpty,
    );
  });

  testWidgets('Clear takes away every kind of time on the Action',
      (tester) async {
    await tester.pumpWidget(harness());
    await _settle(tester);

    final actionId =
        (await _real(tester, () => db.actionDao.getCurrentAction('o1')))!.id;
    await _real(tester, () => db.actionDao.setTimeWindow(actionId, windowId));
    // The chip reads the windows of the current Actions: let them arrive.
    await _settle(tester);

    await openChip(tester);
    expect(find.byKey(const Key('time_context_clear')), findsOneWidget);

    // While the sheet is open, the Action's time is replaced by a one-time
    // time — a peer did it, or another surface did.
    await _real(
      tester,
      () => db.actionDao.setTimeContext(
        actionId,
        TimeContext.create(fromDate: DateTime(2026, 11, 30)),
      ),
    );

    await tester.tap(find.byKey(const Key('time_context_clear')));
    await _settle(tester);

    final action = await _real(tester, () => db.select(db.actions).getSingle());
    expect(action.timeWindowId, isNull);
    expect(action.timeContext, isNull);
  });

  testWidgets('the sheet lays out at 320dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTimeContextSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'the sheet lays out clean at 320dp');

    await tester.tap(find.byKey(const Key('time_context_choice_window')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the window list lays out clean at 320dp');
  });
}
