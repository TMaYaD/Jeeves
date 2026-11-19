/// The estimate sheet: the stepper and the Timeboxed switch (issue #923).
///
/// The sheet is the one place the estimate and the switch are set together, so
/// what is pinned here is the relationship between them: the switch is written
/// on the Action, the estimate on the Outcome, the switch needs an estimate,
/// and clearing the estimate clears the switch with it.
///
/// Writes land in a real in-memory database — no mocks ("test real behavior
/// only"); the assertions read the rows back.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/widgets/outcome_attribute_editors.dart';
import 'package:jeeves/widgets/timeboxed_glyph.dart';

import '../test_helpers.dart';

const _userId = 'local';
final _ts = DateTime.utc(2026, 11, 16, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late TaskDetailNotifier notifier;
  late String actionId;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await db.todoDao.insertOutcome(
      id: 't1',
      title: 'Write the report',
      userId: _userId,
      now: _ts,
    );
    await db.actionDao.setCurrentAction(
      't1',
      'Draft',
      timeEstimate: 30,
      now: _ts,
    );
    actionId = (await db.actionDao.getCurrentAction('t1'))!.id;
    notifier = TaskDetailNotifier(db: db, userId: _userId, todoId: 't1');
  });
  tearDown(() async => db.close());

  Widget harness({int? current, bool timeboxed = false, int? actionEstimate = 30}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showOutcomeTimeEstimateSheet(
                context,
                notifier,
                current: current,
                actionText: 'Draft',
                actionId: actionId,
                timeboxed: timeboxed,
                actionEstimate: actionEstimate,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(
    WidgetTester tester, {
    int? current,
    bool timeboxed = false,
    int? actionEstimate = 30,
  }) async {
    await tester.pumpWidget(harness(
      current: current,
      timeboxed: timeboxed,
      actionEstimate: actionEstimate,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Lets the sheet's real database writes finish, then settles the sheet's
  /// exit animation.
  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();
  }

  Future<int?> storedEstimate(WidgetTester tester) async =>
      (await tester.runAsync(() => db.todoDao.getTodo('t1')))?.timeEstimate;

  Future<bool?> storedTimeboxed(WidgetTester tester) async =>
      (await tester.runAsync(
        () => db.actionDao.getCurrentAction('t1'),
      ))?.timeboxed;

  testWidgets('the sheet opens on the current estimate', (tester) async {
    await openSheet(tester, current: 30);

    expect(find.byKey(const Key('estimate_sheet_value')), findsOneWidget);
    expect(find.text('30m'), findsOneWidget);
  });

  testWidgets('an Outcome with no estimate opens on "no estimate"', (
    tester,
  ) async {
    await openSheet(tester);

    expect(find.text('No estimate'), findsOneWidget);
  });

  testWidgets('stepping up and down walks the ladder', (tester) async {
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_more')));
    await tester.pump();
    expect(find.text('45m'), findsOneWidget);

    await tester.tap(find.byKey(const Key('estimate_sheet_less')));
    await tester.pump();
    expect(find.text('30m'), findsOneWidget);

    await tester.tap(find.byKey(const Key('estimate_sheet_less')));
    await tester.pump();
    expect(find.text('15m'), findsOneWidget);
  });

  testWidgets('stepping below the shortest value leaves no estimate', (
    tester,
  ) async {
    await openSheet(tester, current: 5);

    await tester.tap(find.byKey(const Key('estimate_sheet_less')));
    await tester.pump();

    expect(find.text('No estimate'), findsOneWidget);
  });

  testWidgets('the Timeboxed switch is unavailable without an estimate', (
    tester,
  ) async {
    await openSheet(tester);

    final toggle = tester.widget<InkWell>(
      find.byKey(const Key('estimate_sheet_timeboxed')),
    );
    expect(toggle.onTap, isNull);
  });

  testWidgets('the Timeboxed switch is written on the Action', (tester) async {
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_timeboxed')));
    await tester.pump();
    await save(tester);

    expect(await storedTimeboxed(tester), isTrue);
  });

  testWidgets('a moved estimate is written on the Outcome', (tester) async {
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_more')));
    await tester.pump();
    await save(tester);

    expect(await storedEstimate(tester), 45);
  });

  testWidgets('saving without a change writes nothing', (tester) async {
    await openSheet(tester, current: 30);
    final before = await tester.runAsync(() => db.todoDao.getTodo('t1'));

    await save(tester);

    expect(await tester.runAsync(() => db.todoDao.getTodo('t1')), before);
  });

  testWidgets('the sheet shows the Timeboxed mark', (tester) async {
    await openSheet(tester, current: 30);

    expect(find.byType(TimeboxedGlyph), findsOneWidget);
  });

  testWidgets('turning the switch on when the Action has no estimate of its '
      'own writes the estimate with it', (tester) async {
    // The merge state: the Outcome's mirror holds the estimate and the
    // Action's own copy is empty. The limit is the Action's estimate, so the
    // switch needs that one — and the estimate the sheet shows is written
    // with it.
    await db.customStatement('UPDATE actions SET time_estimate = NULL');
    await openSheet(tester, current: 30, actionEstimate: null);

    await tester.tap(find.byKey(const Key('estimate_sheet_timeboxed')));
    await tester.pump();
    await save(tester);

    final action =
        await tester.runAsync(() => db.actionDao.getCurrentAction('t1'));
    expect(action!.timeboxed, isTrue);
    expect(action.timeEstimate, 30);
  });
}
