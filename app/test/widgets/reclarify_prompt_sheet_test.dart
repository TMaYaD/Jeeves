/// Widget tests for [ReclarifyPromptSheet] (issue #469).
///
/// The sheet is only a shell around the canonical [ProcessToHandlers] bar, so
/// these tests pin the sheet-specific behaviour: the four ruled verdicts render
/// (no Trash), each routes correctly against a real [GtdDatabase], "More to
/// do…" opens the next-action dialog empty, and dismissing writes nothing.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Ship the thing',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

Future<void> _insertPersonTag(
  GtdDatabase db, {
  required String id,
  required String name,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: const Value('person'),
    userId: const Value(_userId),
  ));
}

Tag _personTag(String id, String name) =>
    Tag(id: id, name: name, type: 'person', userId: _userId);

/// Pumps a screen with a single button that floats the sheet for [todo] and
/// records the resolved [ProcessAction] (or null on dismiss).
Future<List<ProcessAction?>> _pumpAndOpen(
  WidgetTester tester,
  GtdDatabase db, {
  required Todo todo,
  List<Tag> personTags = const [],
}) async {
  final results = <ProcessAction?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  results.add(await ReclarifyPromptSheet.show(context, todo));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

/// Pumps a screen with a single button that floats the "Approach stopped"
/// sheet for [seeded]'s Outcome, and records the resolved [ProcessAction] (or
/// null on dismiss).
///
/// The Jeeves line is fixed, so the test can name it.
Future<List<ProcessAction?>> _pumpAndOpenStopped(
  WidgetTester tester,
  GtdDatabase db, {
  required ({Todo todo, String actionId, DateTime? lastClarifiedAt}) seeded,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final results = <ProcessAction?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        // The sheet is a bottom sheet on the root navigator, so the scale has
        // to be set above it.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  results.add(
                    await ReclarifyPromptSheet.showApproachStopped(
                      context,
                      seeded.todo,
                      stoppingActionId: seeded.actionId,
                      jeevesLine: 'That approach has had its time, sir. '
                          'Where does the matter stand?',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  testWidgets('renders the four ruled verdicts, header, and no Trash',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r1');
    await _pumpAndOpen(tester, db, todo: todo);

    expect(find.byType(ReclarifyPromptSheet), findsOneWidget);
    expect(find.text('Action complete'), findsOneWidget);
    expect(find.text('Outcome achieved'), findsOneWidget);
    expect(find.text('More to do…'), findsOneWidget);
    expect(find.text('Waiting on someone…'), findsOneWidget);
    expect(find.text('Defer to Someday'), findsOneWidget);
    // Trash is not one of the ruled verdicts.
    expect(find.text('Trash'), findsNothing);
    // The Action-Done vs Outcome-Done disambiguation: no plain "Done".
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('Outcome achieved records Completion and resolves done',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r2');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('Outcome achieved'));
    await tester.pumpAndSettle();

    final row = await db.todoDao.getTodo('r2');
    expect(row?.doneAt, isNotNull);
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.done]);
  });

  testWidgets(
      'More to do… opens the dialog empty; saving creates a current Action',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r3');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('More to do…'));
    await tester.pumpAndSettle();

    // The cursor was cleared by completeCurrentAction, so the dialog opens
    // empty — nothing is prefilled.
    expect(find.byType(NextActionDialog), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(NextActionDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller?.text, '');

    await tester.enterText(
      find.descendant(
        of: find.byType(NextActionDialog),
        matching: find.byType(TextField),
      ),
      'Draft the outline',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final current = await db.actionDao.getCurrentAction('r3');
    expect(current?.actionText, 'Draft the outline');
    final row = await db.todoDao.getTodo('r3');
    expect(row?.intent, 'next');
    expect(row?.doneAt, isNull);
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.nextActionDialog]);
  });

  testWidgets('More to do… with a blank save falls back to the title (#691)',
      (tester) async {
    // The sheet is a shell around the shared bar, so it inherits the
    // title-as-action fallback: the user who knows there is more to
    // do but cannot name it is not held on the sheet. It matters most here —
    // completeCurrentAction has just left the Outcome Actionless, which is the
    // state that re-arms the re-clarification queue with no freshness gate.
    final todo = await _insertTodo(db, id: 'r4', title: 'Ship the thing');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('More to do…'));
    await tester.pumpAndSettle();
    // Save without entering text.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await db.actionDao.getCurrentAction('r4'))?.actionText,
        'Ship the thing');
    final row = await db.todoDao.getTodo('r4');
    expect(row?.intent, 'next');
    expect(row?.doneAt, isNull,
        reason: 'more to do is not an Outcome achievement');
    expect(row?.lastClarifiedAt, isNotNull);
    // Still not a `done` verdict — the focus screen keys "All done for today!"
    // on that specifically, and this resolution must not claim it.
    expect(results, [ProcessAction.nextActionDialog]);
  });

  testWidgets('Waiting on someone… delegates and resolves waitingFor',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r5');
    await _insertPersonTag(db, id: 'alice', name: 'Alice');
    final results = await _pumpAndOpen(
      tester,
      db,
      todo: todo,
      personTags: [_personTag('alice', 'Alice')],
    );

    await tester.tap(find.text('Waiting on someone…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();

    expect(await db.todoDao.getPersonTagIdsForTodo('r5'), contains('alice'));
    final row = await db.todoDao.getTodo('r5');
    expect(row?.intent, 'next');
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.waitingFor]);
  });

  testWidgets('Defer to Someday sets intent maybe and resolves someday',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r6');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    await tester.tap(find.text('Defer to Someday'));
    await tester.pumpAndSettle();

    final row = await db.todoDao.getTodo('r6');
    expect(row?.intent, 'maybe');
    expect(row?.lastClarifiedAt, isNotNull);
    expect(results, [ProcessAction.someday]);
  });

  testWidgets('dismissing the sheet writes nothing and resolves null',
      (tester) async {
    final todo = await _insertTodo(db, id: 'r7');
    final results = await _pumpAndOpen(tester, db, todo: todo);

    // Tap the modal barrier above the sheet to dismiss it.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(find.byType(ReclarifyPromptSheet), findsNothing);
    expect(await db.actionDao.getCurrentAction('r7'), isNull);
    final row = await db.todoDao.getTodo('r7');
    expect(row?.intent, 'next', reason: 'dismiss must not route');
    expect(row?.doneAt, isNull);
    expect(row?.lastClarifiedAt, isNull);
    expect(results, [null]);
  });

  group('the approach-stopped sheet', () {
    /// An Outcome with a current Action that has logged time — an approach
    /// that ran out of time.
    Future<({Todo todo, String actionId, DateTime? lastClarifiedAt})>
        seedStopped({
      required String id,
    }) async {
      final now = DateTime.now().toUtc();
      await db.todoDao.insertOutcome(
        id: id,
        title: 'Write the report',
        userId: _userId,
        now: now,
      );
      await db.actionDao.setCurrentAction(
        id,
        'Draft the report',
        timeEstimate: 30,
        now: now,
      );
      await db.timeLogDao.openLog(
        taskId: id,
        userId: _userId,
        now: now.subtract(const Duration(minutes: 25)),
      );
      await db.timeLogDao.closeLog(taskId: id, now: now);
      final action = (await db.actionDao.getCurrentAction(id))!;
      final todo = (await db.todoDao.getTodo(id))!;
      return (
        todo: todo,
        actionId: action.id,
        lastClarifiedAt: todo.lastClarifiedAt,
      );
    }

    testWidgets('heads "Approach stopped" and offers the Done sheet\'s four '
        'choices', (tester) async {
      final seeded = await seedStopped(id: 's1');
      await _pumpAndOpenStopped(tester, db, seeded: seeded);

      expect(find.text('Approach stopped'), findsOneWidget);
      // A Jeeves line, from the pool, under the heading.
      expect(
        find.text('That approach has had its time, sir. '
            'Where does the matter stand?'),
        findsOneWidget,
      );
      expect(find.text('Outcome achieved'), findsOneWidget);
      expect(find.text('More to do…'), findsOneWidget);
      expect(find.text('Waiting on someone…'), findsOneWidget);
      expect(find.text('Defer to Someday'), findsOneWidget);
      expect(find.text('Trash'), findsNothing);
    });

    testWidgets('the four choices carry the Done sheet\'s icons and colours',
        (tester) async {
      final seeded = await seedStopped(id: 's2');
      await _pumpAndOpenStopped(tester, db, seeded: seeded);

      Future<void> expectChoice(
        String label,
        IconData icon,
        Color colour,
      ) async {
        final button = find.widgetWithText(OutlinedButton, label);
        expect(button, findsOneWidget);
        final found = tester.widget<Icon>(
          find.descendant(of: button, matching: find.byIcon(icon)),
        );
        expect(found.color, colour, reason: 'the icon for "$label"');
      }

      await expectChoice(
          'Outcome achieved', Icons.task_alt_outlined, const Color(0xFF16A34A));
      await expectChoice(
          'More to do…', Icons.check_circle_outline, const Color(0xFF2563EB));
      await expectChoice(
          'Waiting on someone…', Icons.person_outlined, const Color(0xFF7C3AED));
      await expectChoice(
          'Defer to Someday', Icons.star_border, const Color(0xFF6B7280));
    });

    testWidgets('the sheet announces itself to a screen reader',
        (tester) async {
      final seeded = await seedStopped(id: 's3');
      await _pumpAndOpenStopped(tester, db, seeded: seeded);

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Approach stopped',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the four choices meet the tap-target guideline',
        (tester) async {
      final seeded = await seedStopped(id: 's4');
      await _pumpAndOpenStopped(tester, db, seeded: seeded);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('the four choices still fit at a doubled text scale',
        (tester) async {
      final seeded = await seedStopped(id: 's5');
      await _pumpAndOpenStopped(
        tester,
        db,
        seeded: seeded,
        textScaler: const TextScaler.linear(2.0),
      );

      // Nothing overflowed, and no label was cut short.
      expect(tester.takeException(), isNull);
      for (final label in const [
        'Outcome achieved',
        'More to do…',
        'Waiting on someone…',
        'Defer to Someday',
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
      }
    });

    testWidgets('the verdict closes the Action at its limit and keeps its '
        'logged time', (tester) async {
      final seeded = await seedStopped(id: 's6');
      final results = await _pumpAndOpenStopped(tester, db, seeded: seeded);

      await tester.tap(find.text('Outcome achieved'));
      await tester.pumpAndSettle();

      final action = (await db.actionDao.getCurrentAction('s6'));
      expect(action, isNull, reason: 'the Outcome has no current Action now');
      final history = await db.actionDao.getTerminatedActions('s6');
      expect(history, hasLength(1));
      expect(history.single.action.id, seeded.actionId);
      // Superseded, not done: the approach ran out of time.
      expect(history.single.action.role, 'superseded');
      expect(history.single.action.stoppedAtLimitAt, isNotNull);
      // The time it logged is still its own.
      expect(history.single.loggedMinutes, 25);
      expect(results, [ProcessAction.done]);
    });

    testWidgets('Outcome achieved records the Completion and leaves the '
        'Action stopped at the limit', (tester) async {
      final seeded = await seedStopped(id: 's7');
      await _pumpAndOpenStopped(tester, db, seeded: seeded);

      await tester.tap(find.text('Outcome achieved'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('s7');
      expect(row?.doneAt, isNotNull, reason: 'the Outcome is achieved');
      final history = await db.actionDao.getTerminatedActions('s7');
      expect(history.single.action.role, 'superseded',
          reason: 'the Action itself was not done');
      expect(history.single.action.doneAt, isNull);
    });

    testWidgets('dismissing the sheet writes nothing: the Action stays '
        'current', (tester) async {
      final seeded = await seedStopped(id: 's8');
      final results = await _pumpAndOpenStopped(tester, db, seeded: seeded);

      // Tap the modal barrier above the sheet to dismiss it.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      expect(find.byType(ReclarifyPromptSheet), findsNothing);
      final current = await db.actionDao.getCurrentAction('s8');
      expect(current, isNotNull, reason: 'the Action is still current');
      expect(current!.id, seeded.actionId);
      expect(current.stoppedAtLimitAt, isNull);
      final row = await db.todoDao.getTodo('s8');
      expect(row?.doneAt, isNull);
      expect(row?.lastClarifiedAt, seeded.lastClarifiedAt,
          reason: 'the Outcome was not re-clarified');
      expect(results, [null]);
    });
  });
}
