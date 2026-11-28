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

import 'dart:async';

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

/// A notifier whose estimate write is held until the test lets it go, so a
/// save can be observed while its write is still in flight. Once released the
/// write is the real one, against the real in-memory database.
class _HeldWriteNotifier extends TaskDetailNotifier {
  _HeldWriteNotifier({
    required super.db,
    required super.userId,
    required super.todoId,
  });

  final Completer<void> release = Completer<void>();
  int writeCalls = 0;

  @override
  Future<bool> setEstimateAndTimeboxed({
    required String actionId,
    int? minutes,
    bool clearEstimate = false,
    bool? timeboxed,
    int? estimateIfUnset,
  }) async {
    writeCalls++;
    await release.future;
    return super.setEstimateAndTimeboxed(
      actionId: actionId,
      minutes: minutes,
      clearEstimate: clearEstimate,
      timeboxed: timeboxed,
      estimateIfUnset: estimateIfUnset,
    );
  }
}

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

  Widget harness({
    int? current,
    bool timeboxed = false,
    int? initial,
    EstimateRaise? raise,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showOutcomeTimeEstimateSheet(
                context,
                notifier,
                current: current,
                initial: initial,
                actionText: 'Draft',
                actionId: actionId,
                timeboxed: timeboxed,
                raise: raise,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  /// A harness with a screen below the sheet, so a second pop would show it.
  Widget twoRouteHarness() {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: Builder(
                      builder: (ctx) => Center(
                        child: ElevatedButton(
                          key: const Key('open_sheet'),
                          onPressed: () => showOutcomeTimeEstimateSheet(
                            ctx,
                            notifier,
                            current: 30,
                            actionText: 'Draft',
                            actionId: actionId,
                          ),
                          child: const Text('open'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('push'),
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
    int? initial,
    EstimateRaise? raise,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(harness(
      current: current,
      timeboxed: timeboxed,
      initial: initial,
      raise: raise,
      textScaler: textScaler,
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
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_timeboxed')));
    await tester.pump();
    await save(tester);

    final action =
        await tester.runAsync(() => db.actionDao.getCurrentAction('t1'));
    expect(action!.timeboxed, isTrue);
    expect(action.timeEstimate, 30);
  });

  testWidgets('an estimate a peer clears while the sheet is open does not '
      'leave the switch with nothing to limit', (tester) async {
    await openSheet(tester, current: 30);

    // A peer clears the estimate while the sheet is up. The sheet still shows
    // 30, and the switch needs an estimate on the Action to limit.
    await tester.runAsync(() async {
      await db.customStatement('UPDATE actions SET time_estimate = NULL');
      await db.customStatement('UPDATE todos SET time_estimate = NULL');
    });

    await tester.tap(find.byKey(const Key('estimate_sheet_timeboxed')));
    await tester.pump();
    await save(tester);

    final action =
        await tester.runAsync(() => db.actionDao.getCurrentAction('t1'));
    expect(action!.timeboxed, isTrue);
    expect(action.timeEstimate, 30);
  });

  testWidgets('a save with nothing changed cannot be pressed twice over', (
      tester) async {
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await tester.pump();

    // The write is in flight: the button cannot be pressed again.
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('estimate_sheet_save')),
    );
    expect(button.onPressed, isNull);

    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();
  });

  testWidgets('a second save with nothing changed does not take the screen '
      'below the sheet with it', (tester) async {
    await tester.pumpWidget(twoRouteHarness());
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_sheet')));
    await tester.pumpAndSettle();

    // The first save is still writing when the second one arrives.
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('estimate_sheet_save')),
    );
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await tester.pump();
    save.onPressed!();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    // The sheet closed once, and the screen below it is still there.
    expect(find.byKey(const Key('estimate_sheet_save')), findsNothing);
    expect(find.byKey(const Key('open_sheet')), findsOneWidget);
  });

  testWidgets('a save with a write in flight disables Save and writes once, '
      'then closes the sheet once', (tester) async {
    final held = _HeldWriteNotifier(db: db, userId: _userId, todoId: 't1');
    notifier = held;
    await openSheet(tester, current: 30);

    await tester.tap(find.byKey(const Key('estimate_sheet_more')));
    await tester.pump();
    final onSave = tester
        .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
        .onPressed!;
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await tester.pump();

    // The write is suspended: Save is disabled, and a second callback that
    // was already handed out writes nothing more.
    expect(held.writeCalls, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
          .onPressed,
      isNull,
    );
    onSave();
    await tester.pump();
    expect(held.writeCalls, 1);
    expect(find.byKey(const Key('estimate_sheet_save')), findsOneWidget);

    held.release.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('estimate_sheet_save')), findsNothing);
    expect(held.writeCalls, 1);
    expect(await storedEstimate(tester), 45);
  });

  testWidgets('a second save with a write in flight does not take the screen '
      'below the sheet with it', (tester) async {
    final held = _HeldWriteNotifier(db: db, userId: _userId, todoId: 't1');
    notifier = held;
    await tester.pumpWidget(twoRouteHarness());
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_sheet')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('estimate_sheet_more')));
    await tester.pump();
    final onSave = tester
        .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
        .onPressed!;
    await tester.tap(find.byKey(const Key('estimate_sheet_save')));
    await tester.pump();
    // The second save arrives while the first write is suspended.
    onSave();
    await tester.pump();

    held.release.complete();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();

    // The sheet closed once, and the screen below it is still there.
    expect(held.writeCalls, 1);
    expect(find.byKey(const Key('estimate_sheet_save')), findsNothing);
    expect(find.byKey(const Key('open_sheet')), findsOneWidget);
  });

  group('raise mode', () {
    /// The raise the gate opens: 60 minutes of limit, 82 minutes logged.
    final raise = EstimateRaise(
      outcomeTitle: 'Write the report',
      limitMinutes: 60,
      logged: const Duration(minutes: 82),
    );

    testWidgets('it names the Outcome, the limit and the time logged', (
      tester,
    ) async {
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      expect(find.text('Write the report'), findsOneWidget);
      expect(find.text('Current limit: 1h'), findsOneWidget);
      expect(
        find.text('Logged so far: 1h 22m, breaks included'),
        findsOneWidget,
      );
      expect(find.text('I shall re-flow the rest of the day.'), findsOneWidget);
    });

    testWidgets('Save is unavailable until the value beats the time logged', (
      tester,
    ) async {
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      // 90 minutes is more than the 82 logged, so the sheet can be saved.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
            .onPressed,
        isNotNull,
      );
      expect(
        find.text('Must be more than the 1h 22m already logged.'),
        findsNothing,
      );

      // One step down is 60 minutes — short of the time logged.
      await tester.tap(find.byKey(const Key('estimate_sheet_less')));
      await tester.pump();

      expect(find.text('1h'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
            .onPressed,
        isNull,
      );
      expect(
        find.text('Must be more than the 1h 22m already logged.'),
        findsOneWidget,
      );

      // Back up, and the sheet can be saved again.
      await tester.tap(find.byKey(const Key('estimate_sheet_more')));
      await tester.pump();

      expect(find.text('1h 30m'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('estimate_sheet_save')))
            .onPressed,
        isNotNull,
      );
      expect(
        find.text('Must be more than the 1h 22m already logged.'),
        findsNothing,
      );
    });

    testWidgets('the refusal is plain text, not an error', (tester) async {
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      await tester.tap(find.byKey(const Key('estimate_sheet_less')));
      await tester.pump();

      final style = tester
          .widget<Text>(
            find.text('Must be more than the 1h 22m already logged.'),
          )
          .style;
      final theme = Theme.of(
        tester.element(find.byKey(const Key('estimate_sheet_value'))),
      );
      expect(style?.color, isNot(theme.colorScheme.error));
      expect(style?.color, isNot(const Color(0xFFDC2626)));
    });

    testWidgets('the Timeboxed switch is not shown', (tester) async {
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      expect(find.byKey(const Key('estimate_sheet_timeboxed')), findsNothing);
    });

    testWidgets('a raise writes the estimate and leaves the Action '
        'Timeboxed', (tester) async {
      await db.todoDao.updateFields('t1', timeboxed: true, now: _ts);
      await openSheet(
        tester,
        current: 30,
        initial: 90,
        timeboxed: true,
        raise: raise,
      );

      await save(tester);

      expect(await storedEstimate(tester), 90);
      expect(await storedTimeboxed(tester), isTrue);
    });

    testWidgets('the sheet carries a screen-reader label', (tester) async {
      final handle = tester.ensureSemantics();
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      expect(
        find.bySemanticsLabel('Raise the estimate for Draft'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the touch targets are at least 48dp', (tester) async {
      final handle = tester.ensureSemantics();
      await openSheet(tester, current: 30, initial: 90, raise: raise);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the buttons are not truncated at a large text scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await openSheet(
        tester,
        current: 30,
        initial: 90,
        raise: raise,
        textScaler: const TextScaler.linear(2.0),
      );

      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Very good'), findsOneWidget);
    });

    testWidgets('without a raise none of the new lines show', (tester) async {
      await openSheet(tester, current: 30);

      expect(find.text('Current limit: 1h'), findsNothing);
      expect(find.textContaining('Logged so far'), findsNothing);
      expect(find.text('I shall re-flow the rest of the day.'), findsNothing);
      expect(find.byKey(const Key('estimate_sheet_timeboxed')), findsOneWidget);
    });
  });
}
