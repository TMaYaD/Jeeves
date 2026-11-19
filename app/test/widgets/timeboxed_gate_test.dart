/// The gate before a Sprint started past a Timeboxed limit (issue #923).
///
/// The gate is exercised over a real in-memory database: the limit is
/// derived from the Action's estimate, its TimeLogs and its Sprints, so the
/// assertions read the same rows the app reads. The sheet is driven by taps
/// — confirm, dismiss, or raise the estimate — and what the guard does
/// afterwards is asserted against the rows it wrote.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/timeboxed_gate.dart';
import 'package:jeeves/widgets/timeboxed_limit_strip.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Lets the gate's real database reads and writes finish, then settles the
/// sheet's animation.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => pumpEventQueue());
  await tester.pumpAndSettle();
  await tester.pump();
}

/// The screen the tests drive: one button that asks the guard to start.
class _GateHarness extends ConsumerWidget {
  const _GateHarness({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const Key('open_gate'),
          onPressed: () {
            unawaited(
              guardSprintPastLimit(
                context,
                ref,
                outcomeId: 't1',
                start: () async => onStart(),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now().toUtc();
    await db.todoDao.insertOutcome(
      id: 't1',
      title: 'Write the report',
      userId: _userId,
      now: now,
    );
    await db.actionDao.setCurrentAction(
      't1',
      'Draft',
      timeEstimate: 30,
      now: now,
    );
  });
  tearDown(() async => db.close());

  Widget harness({required VoidCallback onStart}) {
    return ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: _GateHarness(onStart: onStart)),
    );
  }

  /// Turns the current Action Timeboxed.
  Future<void> makeTimeboxed() async {
    await db.todoDao.updateFields(
      't1',
      timeboxed: true,
      now: DateTime.now().toUtc(),
    );
  }

  /// Logs [logged] minutes on the Action, ending just now.
  Future<void> logTime(Duration logged) async {
    final now = DateTime.now().toUtc();
    final opened = now.subtract(logged);
    await db.timeLogDao.openLog(taskId: 't1', userId: _userId, now: opened);
    await db.timeLogDao.closeLog(taskId: 't1', now: now);
  }

  /// Records a Sprint that started past the limit.
  Future<void> recordSprintPastLimit() async {
    await db.sprintDao.startSprint(
      taskId: 't1',
      userId: _userId,
      plannedDurationMinutes: 20,
      now: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );
  }

  Future<int?> storedEstimate() async =>
      (await db.todoDao.getTodo('t1'))?.timeEstimate;

  testWidgets('an Action that is not Timeboxed starts without asking', (
    tester,
  ) async {
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);

    expect(started, isTrue);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
  });

  testWidgets('a limit that has not passed starts without asking', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 10));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);

    expect(started, isTrue);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
  });

  testWidgets('a passed limit asks before the Sprint starts', (tester) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);

    expect(started, isFalse);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
    expect(find.text('The limit has run its course, sir.'), findsOneWidget);
    expect(find.byType(TimeboxedLimitStrip), findsOneWidget);
    expect(find.text('Sprints past the limit so far: 0'), findsOneWidget);
  });

  testWidgets('"Right ho" starts nothing', (tester) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_stop')));
    await settle(tester);

    // The sheet closes and the Sprint does not start.
    expect(started, isFalse);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
  });

  testWidgets('"Another sprint, regardless" asks once more, then starts', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
    await settle(tester);

    // Asked once more: the Sprint has still not started.
    expect(started, isFalse);
    expect(find.byKey(const Key('timeboxed_gate_confirm')), findsOneWidget);
    expect(find.text('Once more, sir, to be certain.'), findsOneWidget);
    expect(find.text('Yes, another sprint'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
    await settle(tester);

    expect(started, isTrue);
  });

  testWidgets('carrying on regardless leaves the estimate as it is', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    await tester.pumpWidget(harness(onStart: () {}));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
    await settle(tester);

    expect(await storedEstimate(), 30);
  });

  testWidgets('"Never mind" at the second ask does not start the Sprint', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_cancel')));
    await settle(tester);

    expect(started, isFalse);
    expect(find.byKey(const Key('timeboxed_gate_confirm')), findsNothing);
  });

  testWidgets('"Raise the estimate…" opens the estimate sheet one step up', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    await tester.pumpWidget(harness(onStart: () {}));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_raise')));
    await settle(tester);

    expect(find.byKey(const Key('estimate_sheet_value')), findsOneWidget);
    // The estimate is 30; the sheet opens on the step above it.
    expect(find.text('45m'), findsOneWidget);
  });

  testWidgets('cancelling the estimate sheet returns to the gate', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_raise')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('estimate_sheet_cancel')));
    await settle(tester);

    // Back at the gate, with the estimate untouched and no Sprint started.
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
    expect(find.byKey(const Key('estimate_sheet_value')), findsNothing);
    expect(await storedEstimate(), 30);
    expect(started, isFalse);
  });

  testWidgets('a raised estimate that is still short asks again, and does '
      'not start', (tester) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_raise')));
    await settle(tester);
    // The sheet opened one step up: 30 becomes 45, and 50 minutes are logged —
    // the limit is still passed.
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await settle(tester);

    expect(await storedEstimate(), 45);
    expect(started, isFalse);
    // The gate asks again, with the figures as they now stand.
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
    expect(find.text('Sprints past the limit so far: 0'), findsOneWidget);
  });

  testWidgets('a raised estimate that clears the limit starts the Sprint', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_raise')));
    await settle(tester);
    // One step further: 45 becomes 60, and 50 minutes are logged — the limit
    // is no longer passed.
    await tester.tap(find.byKey(const Key('estimate_sheet_more')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await settle(tester);

    expect(await storedEstimate(), 60);
    expect(started, isTrue);
  });

  testWidgets('the second Sprint past the limit is firmer', (tester) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    await recordSprintPastLimit();
    var started = false;
    await tester.pumpWidget(harness(onStart: () => started = true));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);

    expect(started, isFalse);
    expect(
      find.text('That would be the second past the limit, sir.'),
      findsOneWidget,
    );
    expect(find.text('Sprints past the limit so far: 1'), findsOneWidget);
  });

  testWidgets('a sheet that goes without a choice leaves the gate open', (
    tester,
  ) async {
    await makeTimeboxed();
    await logTime(const Duration(minutes: 50));
    await tester.pumpWidget(harness(onStart: () {}));

    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);

    // The sheet goes without a choice — the screen is left, as it is when the
    // user walks away from it.
    await tester.pumpWidget(harness(onStart: () {}));
    await settle(tester);

    // The gate asks again: a sheet that was never answered is not a gate that
    // has been shut.
    await tester.tap(find.byKey(const Key('open_gate')));
    await settle(tester);
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
  });
}
