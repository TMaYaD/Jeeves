/// Widget tests for [ClarifyCard]'s routing behaviour (#293 regression).
///
/// `ClarifyCard` opts out of the default-on `nextActionDialog` modifier
/// (`except: {nextActionDialog}`) because it supplies the next-action phrase
/// through the title-as-action coupling instead. Tapping Next must therefore
/// stay a one-tap route — no dialog — and still leave the row with a defined
/// `next_action_text`.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/person_tag_picker.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertInboxTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Buy milk',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        captureSource: const Value('manual'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

Future<Tag> _insertTag(
  GtdDatabase db, {
  required String id,
  required String name,
  required String type,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: Value(type),
    userId: const Value(_userId),
  ));
  return (db.select(db.tags)..where((t) => t.id.equals(id))).getSingle();
}

Future<void> _assignTag(
  GtdDatabase db, {
  required String todoId,
  required String tagId,
}) =>
    db.tagDao.assignTag(todoId, tagId, _userId);

/// Reads the tag ids currently joined to [todoId] via `todo_tags`.
Future<Set<String>> _joinedTagIds(GtdDatabase db, String todoId) async {
  final rows = await (db.select(db.todoTags)
        ..where((t) => t.todoId.equals(todoId)))
      .get();
  return {for (final r in rows) r.tagId};
}

/// Reads the [Tag] rows joined to [todoId] — mirrors [taskTagsProvider]'s query
/// so tests can feed live DB state through a controllable stream (avoiding the
/// pending-timer that a real drift `watch()` leaves behind on dispose).
Future<List<Tag>> _tagsOf(GtdDatabase db, String todoId) {
  final query = db.select(db.tags).join([
    innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
  ])
    ..where(db.todoTags.todoId.equals(todoId));
  return query.map((row) => row.readTable(db.tags)).get();
}

/// Scrolls the card's ListView until the Next Action button is on-screen, then
/// taps it. The Tags section pushes the PROCESS TO bar below the initial
/// viewport, and a ListView doesn't build off-screen children.
Future<void> _tapNextAction(WidgetTester tester) async {
  final next = find.text('Next Action');
  await tester.scrollUntilVisible(
    next,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(next);
}

Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  ClarifyMode mode = ClarifyMode.inbox,
  Future<void> Function(ProcessAction)? onAfterRoute,
  List<Tag> contextTags = const <Tag>[],
  List<Tag> projectTags = const <Tag>[],
  // Stream feeding `taskTagsProvider`. Tag-editing tests pass a StreamController
  // they own (and close in tearDown) so the card re-renders on demand without a
  // real drift `watch()` leaving a pending timer behind on dispose.
  Stream<List<Tag>>? taskTagsStream,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Static streams so drift's StreamQueryStore doesn't leave a pending
      // timer behind on dispose.
      taskDetailTodoProvider(todo.id).overrideWith((_) => Stream.value(todo)),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(contextTags)),
      projectTagsProvider.overrideWith((_) => Stream.value(projectTags)),
      taskTagsProvider(todo.id).overrideWith(
        (_) => taskTagsStream ?? Stream.value(const <Tag>[]),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ClarifyCard(
          todoId: todo.id,
          mode: mode,
          onAfterRoute: onAfterRoute,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ClarifyCard — Next stays a one-tap route (#293)', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'tapping Next does not open NextActionDialog and routes immediately',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 'x', title: 'Buy milk');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        onAfterRoute: (action) async => fired.add(action),
      ));
      await tester.pumpAndSettle();

      await _tapNextAction(tester);
      await tester.pumpAndSettle();

      // Dialog modifier is excepted — no dialog pops.
      expect(find.byType(NextActionDialog), findsNothing);
      // The button reports plain `next`, not the dialog modifier.
      expect(fired, [ProcessAction.next]);

      final row = await db.todoDao.getTodo('x');
      expect(row?.intent, 'next');
      // Title-as-action coupling still mirrors the title into the phrase so
      // the row leaves the inbox with a defined action.
      expect(row?.nextActionText, 'Buy milk');
    });
  });

  group('ClarifyCard — title-as-action mirror is mode-aware', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'reclarify mode does NOT clobber an existing next_action_text',
        (tester) async {
      // Seed a previously-clarified row that already has a deliberate phrase.
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('rc-mirror-1'),
            title: const Value('Plan party'),
            clarified: const Value(true),
            intent: const Value('next'),
            nextActionText: const Value('Email guest list'),
            userId: const Value(_userId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      final todo = (await db.todoDao.getTodo('rc-mirror-1'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        mode: ClarifyMode.reclarify,
      ));
      await tester.pumpAndSettle();

      await _tapNextAction(tester);
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-1');
      expect(row?.nextActionText, 'Email guest list',
          reason: 'reclarify must not overwrite a deliberate phrase with the '
              'title');
      expect(row?.intent, 'next');
    });

    testWidgets(
        'reclarify mode DOES set next_action_text from title when previously '
        'empty', (tester) async {
      await _insertInboxTodo(
        db,
        id: 'rc-mirror-2',
        title: 'Decide on venue',
      );
      // Promote into a clarified-but-actionless state to mirror the
      // production scenario the guard targets.
      await db.todoDao
          .applyRouting('rc-mirror-2', to: RoutingKind.nextAction);
      final fresh = (await db.todoDao.getTodo('rc-mirror-2'))!;

      await tester.pumpWidget(_harness(
        db,
        todo: fresh,
        mode: ClarifyMode.reclarify,
      ));
      await tester.pumpAndSettle();

      await _tapNextAction(tester);
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-2');
      expect(row?.nextActionText, 'Decide on venue',
          reason: 'an empty next_action_text in reclarify mode is filled from '
              'the title so the row leaves with a defined action');
    });
  });

  group('ClarifyCard — tag editing (#304)', () {
    late GtdDatabase db;
    // A controller we own so re-renders are deterministic and no drift `watch()`
    // timer survives disposal. Seed it before pumping and re-emit real DB state
    // after each mutation.
    late StreamController<List<Tag>> tagsCtrl;

    setUp(() {
      db = _openInMemory();
      tagsCtrl = StreamController<List<Tag>>();
    });
    tearDown(() async {
      await tagsCtrl.close();
      await db.close();
    });

    // Re-emit the live join-table state so the pickers rebuild against it.
    // pumpAndSettle so the StreamController event is delivered to the provider
    // (async) before the assertion inspects the rebuilt widget tree.
    Future<void> refreshTags(WidgetTester tester, String todoId) async {
      tagsCtrl.add(await _tagsOf(db, todoId));
      await tester.pumpAndSettle();
    }

    testWidgets('renders a Tags section with empty-state placeholders',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-empty');

      await tester.pumpWidget(
        _harness(db, todo: todo, taskTagsStream: tagsCtrl.stream),
      );
      await tester.pumpAndSettle();

      expect(find.text('TAGS'), findsOneWidget);
      // Project picker's optional-state affordance.
      expect(find.text('No project'), findsOneWidget);
      // Context picker's "add a tag" placeholder chip.
      expect(find.text('+ context'), findsOneWidget);
    });

    testWidgets('assigning a context tag persists via DAO and renders selected',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-ctx-assign');
      final ctx = await _insertTag(db, id: 'c1', name: 'home', type: 'context');

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        contextTags: [ctx],
        taskTagsStream: tagsCtrl.stream,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('@home'));
      await tester.pumpAndSettle();
      await refreshTags(tester, 't-ctx-assign');

      expect(await _joinedTagIds(db, 't-ctx-assign'), contains('c1'));
      // Selected chips render with a ✓ prefix (TagText selected state).
      expect(find.text('✓ @home'), findsOneWidget);
    });

    testWidgets('detaching a context tag removes the join row', (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-ctx-remove');
      final ctx = await _insertTag(db, id: 'c1', name: 'home', type: 'context');
      await _assignTag(db, todoId: 't-ctx-remove', tagId: 'c1');
      tagsCtrl.add([ctx]);

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        contextTags: [ctx],
        taskTagsStream: tagsCtrl.stream,
      ));
      await tester.pumpAndSettle();

      // Tapping the already-selected chip toggles it off.
      await tester.tap(find.text('✓ @home'));
      await tester.pumpAndSettle();
      await refreshTags(tester, 't-ctx-remove');

      expect(await _joinedTagIds(db, 't-ctx-remove'), isNot(contains('c1')));
      expect(find.text('✓ @home'), findsNothing);
    });

    testWidgets('assigning a project tag persists via DAO', (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-proj-assign');
      final proj =
          await _insertTag(db, id: 'p1', name: 'Website', type: 'project');

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        projectTags: [proj],
        taskTagsStream: tagsCtrl.stream,
      ));
      await tester.pumpAndSettle();

      // Open the project picker dialog and select the project.
      await tester.tap(find.text('No project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Website').last);
      await tester.pumpAndSettle();
      await refreshTags(tester, 't-proj-assign');

      expect(await _joinedTagIds(db, 't-proj-assign'), contains('p1'));
    });

    testWidgets('switching projects respects the single-project rule',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-proj-switch');
      final p1 = await _insertTag(db, id: 'p1', name: 'Alpha', type: 'project');
      final p2 = await _insertTag(db, id: 'p2', name: 'Beta', type: 'project');
      await _assignTag(db, todoId: 't-proj-switch', tagId: 'p1');
      tagsCtrl.add([p1]);

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        projectTags: [p1, p2],
        taskTagsStream: tagsCtrl.stream,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta').last);
      await tester.pumpAndSettle();
      await refreshTags(tester, 't-proj-switch');

      final joined = await _joinedTagIds(db, 't-proj-switch');
      expect(joined, contains('p2'));
      expect(joined, isNot(contains('p1')),
          reason: 'enforceSingleProject swaps the old project for the new one');
    });

    // Orthogonality invariant (ARCHITECTURE.md): tag edits must not touch the
    // intent axis (next/maybe/trash), the delegate axis (person-tag join
    // rows), or next_action_text.
    for (final intent in const ['next', 'maybe', 'trash']) {
      testWidgets('tag edits leave intent=$intent and delegate axis unchanged',
          (tester) async {
        final now = DateTime.now();
        await db.into(db.todos).insert(TodosCompanion(
              id: Value('orth-$intent'),
              title: const Value('Task'),
              intent: Value(intent),
              nextActionText: const Value('Do the thing'),
              userId: const Value(_userId),
              createdAt: Value(now),
              updatedAt: Value(now),
            ));
        final todo = (await db.todoDao.getTodo('orth-$intent'))!;
        final ctx =
            await _insertTag(db, id: 'c1', name: 'home', type: 'context');
        final proj =
            await _insertTag(db, id: 'p1', name: 'Website', type: 'project');
        // A pre-existing person tag on the row: it must survive every edit.
        final person =
            await _insertTag(db, id: 'per1', name: 'Alice', type: 'person');
        await _assignTag(db, todoId: 'orth-$intent', tagId: 'per1');
        tagsCtrl.add([person]);

        await tester.pumpWidget(_harness(
          db,
          todo: todo,
          contextTags: [ctx],
          projectTags: [proj],
          taskTagsStream: tagsCtrl.stream,
        ));
        await tester.pumpAndSettle();

        Future<void> expectInvariants() async {
          final row = await db.todoDao.getTodo('orth-$intent');
          expect(row?.intent, intent);
          expect(row?.nextActionText, 'Do the thing');
          expect(await _joinedTagIds(db, 'orth-$intent'), contains(person.id),
              reason: 'the delegate axis (person tag) is untouched');
        }

        // Assign context.
        await tester.tap(find.text('@home'));
        await tester.pumpAndSettle();
        await refreshTags(tester, 'orth-$intent');
        await expectInvariants();

        // Detach context.
        await tester.tap(find.text('✓ @home'));
        await tester.pumpAndSettle();
        await refreshTags(tester, 'orth-$intent');
        await expectInvariants();

        // Assign project.
        await tester.tap(find.text('No project'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Website').last);
        await tester.pumpAndSettle();
        await refreshTags(tester, 'orth-$intent');
        await expectInvariants();

        // Clear project.
        await tester.tap(find.text('Website'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove project'));
        await tester.pumpAndSettle();
        await refreshTags(tester, 'orth-$intent');
        await expectInvariants();
      });
    }

    testWidgets('tag edits autosave — no Save button in the Tags section',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-autosave');
      final ctx = await _insertTag(db, id: 'c1', name: 'home', type: 'context');

      await tester.pumpWidget(_harness(
        db,
        todo: todo,
        contextTags: [ctx],
        taskTagsStream: tagsCtrl.stream,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('@home'));
      await tester.pumpAndSettle();
      await refreshTags(tester, 't-autosave');

      // Persisted with no intermediate Save affordance.
      expect(await _joinedTagIds(db, 't-autosave'), contains('c1'));
      expect(find.widgetWithText(ElevatedButton, 'Save'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    });

    testWidgets('person-tag editing is NOT available on the card',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't-no-person');
      // Seed a person tag; it must not be selectable from the card.
      await _insertTag(db, id: 'per1', name: 'Alice', type: 'person');

      await tester.pumpWidget(
        _harness(db, todo: todo, taskTagsStream: tagsCtrl.stream),
      );
      await tester.pumpAndSettle();

      // No person-tag chip and no path to the person picker sheet.
      expect(find.text('@Alice'), findsNothing);
      expect(find.text('✓ @Alice'), findsNothing);
      expect(find.byType(PersonTagPickerSheet), findsNothing);
    });
  });
}
