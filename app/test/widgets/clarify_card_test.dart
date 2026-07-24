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
import 'package:jeeves/widgets/clarify_shared_widgets.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/person_tag_picker.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';
import 'package:jeeves/widgets/state_surfaces.dart';

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

/// Pumps a bounded number of frames instead of [WidgetTester.pumpAndSettle].
///
/// The Capture clarify path writes through the real Drift database, and each
/// [GtdDatabase.notifyCapturesViewWrite] keeps drift's StreamQueryStore
/// emitting, so `pumpAndSettle` never reaches a quiet frame — it spins
/// synchronously and hangs the isolate hard enough that even the per-test
/// timeout can't fire. Bounded pumping is the same tactic the tag-editing
/// group's controlled streams use for the Outcome path.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 40}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Bounded scroll to bring [label] into the viewport, then tap it. The Tags
/// section pushes the PROCESS TO bar below the fold and a ListView doesn't
/// build off-screen children.
Future<void> _scrollAndTap(WidgetTester tester, String label) async {
  for (var i = 0; i < 15 && find.text(label).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(label), findsOneWidget,
      reason: 'the $label button never came into view');
  // Being *built* isn't enough to be tappable: a ListView builds children
  // within its cacheExtent while they still sit below the viewport, and a tap
  // at such a widget's centre hit-tests the empty area instead — silently
  // doing nothing. ensureVisible scrolls it fully into view first.
  await tester.ensureVisible(find.text(label));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(label));
}

/// Ids currently in the Inbox, read with a plain select rather than
/// `CaptureDao.watchInbox().first`. Awaiting a live drift `watch()` inside
/// `testWidgets` never completes — the test binding owns the clock, so the
/// stream's first event is never delivered and the isolate hangs hard enough
/// that the per-test timeout can't fire.
Future<List<String>> _inboxIds(GtdDatabase db) async {
  final rows = await (db.select(db.captures)
        ..where((c) => c.clarifiedAt.isNull()))
      .get();
  return [for (final r in rows) r.id];
}

Future<Capture> _insertCapture(
  GtdDatabase db, {
  required String id,
  String title = 'Buy milk',
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return (await db.captureDao.getCapture(id))!;
}

/// Harness for the re-clarify surface: an Outcome that has already been
/// through the flow once. Every edit autosaves straight to `todos`.
Widget _harness(
  GtdDatabase db, {
  required Todo todo,
  Future<void> Function(ProcessAction)? onAfterRoute,
  List<Tag> contextTags = const <Tag>[],
  List<Tag> projectTags = const <Tag>[],
  // Stream feeding `taskTagsProvider`. Tag-editing tests pass a StreamController
  // they own (and close in tearDown) so the card re-renders on demand without a
  // real drift `watch()` leaving a pending timer behind on dispose.
  Stream<List<Tag>>? taskTagsStream,
  // Stream feeding `taskDetailTodoProvider` — the card's live subject binding
  // on the re-clarify surface. Same rationale as `taskTagsStream`.
  Stream<Todo?>? todoStream,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Static streams so drift's StreamQueryStore doesn't leave a pending
      // timer behind on dispose.
      taskDetailTodoProvider(todo.id).overrideWith(
        (_) => todoStream ?? Stream.value(todo),
      ),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(contextTags)),
      projectTagsProvider.overrideWith((_) => Stream.value(projectTags)),
      taskTagsProvider(todo.id).overrideWith(
        (_) => taskTagsStream ?? Stream.value(const <Tag>[]),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ClarifyCard.forOutcome(
          todoId: todo.id,
          onAfterRoute: onAfterRoute,
        ),
      ),
    ),
  );
}

/// Harness for the Inbox surface: a Capture on its first pass. Routing creates
/// a new Outcome rather than editing one (ADR-0006).
Widget _captureHarness(
  GtdDatabase db, {
  required Capture capture,
  Future<void> Function(ProcessAction)? onAfterRoute,
  List<Tag> contextTags = const <Tag>[],
  List<Tag> projectTags = const <Tag>[],
  Stream<List<Tag>>? tagHintsStream,
  // Stream feeding `captureProvider` — the card's live subject binding. Tests
  // that change (or delete) the row underneath an open card own a controller
  // here and push the re-read row down it, exactly as a live drift `watch()`
  // would, without leaving a pending timer behind on dispose.
  Stream<Capture?>? captureStream,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      captureProvider(capture.id).overrideWith(
        (_) => captureStream ?? Stream.value(capture),
      ),
      captureTagHintsProvider(capture.id).overrideWith(
        (_) => tagHintsStream ?? Stream.value(const <Tag>[]),
      ),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(contextTags)),
      projectTagsProvider.overrideWith((_) => Stream.value(projectTags)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ClarifyCard.forCapture(
          captureId: capture.id,
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
      final capture = await _insertCapture(db, id: 'x', title: 'Buy milk');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        onAfterRoute: (action) async => fired.add(action),
      ));
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      // Dialog modifier is excepted — no dialog pops.
      expect(find.byType(NextActionDialog), findsNothing);
      // The button reports plain `next`, not the dialog modifier.
      expect(fired, [ProcessAction.next]);

      // Clarifying a Capture *creates* an Outcome rather than flipping a
      // column (ADR-0006): exactly one, linked back and routed.
      final outcomeIds = await db.captureDao.outcomeIdsForCapture('x');
      expect(outcomeIds, hasLength(1));
      final row = await db.todoDao.getTodo(outcomeIds.single);
      expect(row?.intent, 'next');
      // Title-as-action coupling still mirrors the title into the phrase so
      // the row leaves the inbox with a defined action.
      expect(row?.nextActionText, 'Buy milk');
      // And the Capture is stamped, so it leaves the Inbox.
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNotNull);
      expect(await _inboxIds(db), isEmpty);
    });

    testWidgets('Discard stamps the Capture without creating an Outcome',
        (tester) async {
      final capture = await _insertCapture(db, id: 'junk', title: 'Noise');
      final fired = <ProcessAction>[];
      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        onAfterRoute: (action) async => fired.add(action),
      ));
      await _pumpFrames(tester, frames: 5);

      // On a Capture the action is labelled "Discard Capture", not "Trash":
      // it creates no Outcome, so it never reaches the Trash List, and it ends
      // the Capture rather than routing one Outcome.
      await _scrollAndTap(tester, 'Discard Capture');
      await _pumpFrames(tester);

      // Discarding a Capture is a stamp-only verdict, not a created-then-
      // trashed Outcome. Nothing lands on the Trash List, which stays a
      // record of Outcomes.
      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.captureDao.outcomeIdsForCapture('junk'), isEmpty);
      // The Capture itself survives as the record of the discard.
      expect((await db.captureDao.getCapture('junk'))!.clarifiedAt, isNotNull);
      expect(await _inboxIds(db), isEmpty);
      expect(fired, [ProcessAction.trash]);
    });

    testWidgets(
        'a tag added just before routing still reaches the new Outcome',
        (tester) async {
      final capture = await _insertCapture(db, id: 'racy', title: 'Ship it');
      final ctx = await _insertTag(db, id: 'c1', name: 'work', type: 'context');

      // A controller that emits the initial (empty) hints and nothing more —
      // standing in for the real stream not having caught up yet. The picker
      // callback's DAO write is `unawaited`, so without a synchronously
      // maintained draft the route below would carry the pre-tap hints and
      // silently drop the tag from the Outcome.
      final hints = StreamController<List<Tag>>();
      addTearDown(hints.close);
      hints.add(const <Tag>[]);

      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        contextTags: [ctx],
        tagHintsStream: hints.stream,
      ));
      await _pumpFrames(tester, frames: 5);

      await tester.ensureVisible(find.text('@work'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('@work'));
      await tester.pump();

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      final outcomeId =
          (await db.captureDao.outcomeIdsForCapture('racy')).single;
      expect(await _joinedTagIds(db, outcomeId), contains('c1'));
    });

    testWidgets('tag hints on the Capture seed the new Outcome\'s tags',
        (tester) async {
      final capture = await _insertCapture(db, id: 'hinted', title: 'Ship it');
      final ctx = await _insertTag(db, id: 'c1', name: 'work', type: 'context');
      await db.captureDao.assignTagHint('hinted', 'c1', _userId);

      await tester.pumpWidget(_captureHarness(
        db,
        capture: capture,
        contextTags: [ctx],
        tagHintsStream: Stream.value([ctx]),
      ));
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      final outcomeId =
          (await db.captureDao.outcomeIdsForCapture('hinted')).single;
      expect(await _joinedTagIds(db, outcomeId), contains('c1'),
          reason: 'a tag hint is a hint *for* clarification — it carries onto '
              'the Outcome the Capture becomes');
    });
  });

  group('ClarifyCard — re-clarify does not clobber a deliberate phrase', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        're-clarify does NOT clobber an existing next_action_text',
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
      ));
      await tester.pumpAndSettle();

      await _tapNextAction(tester);
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-1');
      expect(row?.nextActionText, 'Email guest list',
          reason: 're-clarify must not overwrite a deliberate phrase with the '
              'title');
      expect(row?.intent, 'next');
    });

    testWidgets(
        're-clarify DOES set next_action_text from title when previously '
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
      ));
      await tester.pumpAndSettle();

      await _tapNextAction(tester);
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('rc-mirror-2');
      expect(row?.nextActionText, 'Decide on venue',
          reason: 'an empty next_action_text on re-clarify is filled from '
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
    // rows), or next_action_text. The invariant is independent of which intent
    // the row holds, so one representative value ('next') exercises the same
    // code path all three would.
    testWidgets('tag edits leave intent and delegate axis unchanged',
        (tester) async {
      const intent = 'next';
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('orth-$intent'),
            title: const Value('Task'),
            intent: const Value(intent),
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

  // The card seeded its fields from the first subject it saw and then ignored
  // the row for the rest of its life, so a change underneath it was invisible
  // and a delete left it looking editable. It now reconciles on every
  // emission (#427).
  group('ClarifyCard — live subject binding', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    String titleText(WidgetTester tester) =>
        tester
            .widget<TextField>(find.byKey(const Key('clarify_title')))
            .controller
            ?.text ??
        '';

    String notesText(WidgetTester tester) =>
        tester
            .widget<TextField>(find.byKey(const Key('clarify_notes')))
            .controller
            ?.text ??
        '';

    testWidgets('Capture card adopts a change to an untouched field',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x', title: 'Buy milk');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _captureHarness(db, capture: capture, captureStream: feed.stream),
      );
      feed.add(capture);
      await _pumpFrames(tester, frames: 5);
      expect(titleText(tester), 'Buy milk');

      // The row changes in local storage. Where the change came from is not
      // something this card can know, or needs to.
      await db.captureDao
          .updateFields('x', title: 'Buy oat milk', notes: 'Barista');
      feed.add(await db.captureDao.getCapture('x'));
      await _pumpFrames(tester, frames: 5);

      expect(titleText(tester), 'Buy oat milk');
      expect(notesText(tester), 'Barista');
    });

    testWidgets('Capture card leaves the field being edited alone',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x', title: 'Buy milk');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _captureHarness(db, capture: capture, captureStream: feed.stream),
      );
      feed.add(capture);
      await _pumpFrames(tester, frames: 5);

      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Buy almond milk');
      await tester.pump();

      await db.captureDao
          .updateFields('x', title: 'Buy oat milk', notes: 'Barista');
      feed.add(await db.captureDao.getCapture('x'));
      await _pumpFrames(tester, frames: 5);

      // Dirty field keeps the user's edit; the clean one takes the change.
      expect(titleText(tester), 'Buy almond milk');
      expect(notesText(tester), 'Barista');

      // Let the autosave debounce fire before the card is torn down. Disposing
      // with an unflushed edit takes the card's fire-and-forget flush path,
      // which reads a provider from `dispose()` and throws under the test
      // binding — a latent bug of its own, not what this test is pinning.
      await _pumpFrames(tester, frames: 15);
    });

    testWidgets('Capture card stops being editable once the row is gone',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x', title: 'Buy milk');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _captureHarness(db, capture: capture, captureStream: feed.stream),
      );
      feed.add(capture);
      await _pumpFrames(tester, frames: 5);
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);

      await db.captureDao.deleteCapture('x');
      feed.add(null);
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(const Key('clarify_title')), findsNothing);
      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
    });

    testWidgets('Outcome card adopts a change to an untouched field',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't', title: 'Buy milk');
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _harness(db, todo: todo, todoStream: feed.stream),
      );
      feed.add(todo);
      await _pumpFrames(tester, frames: 5);

      await db.todoDao
          .updateFields('t', title: 'Buy oat milk', energyLevel: 'low');
      feed.add(await db.todoDao.getTodo('t'));
      await _pumpFrames(tester, frames: 5);

      expect(titleText(tester), 'Buy oat milk');
      // Energy is an Outcome column, so it reconciles the same way the text
      // does — the picker reflects the stored value.
      expect(
        tester
            .widget<ClarifyEnergyPicker>(find.byType(ClarifyEnergyPicker))
            .selected,
        'low',
      );
    });

    testWidgets('Outcome card stops being editable once the row is gone',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't', title: 'Buy milk');
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _harness(db, todo: todo, todoStream: feed.stream),
      );
      feed.add(todo);
      await _pumpFrames(tester, frames: 5);
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);

      await db.todoDao.deleteOutcome('t');
      feed.add(null);
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(const Key('clarify_title')), findsNothing);
      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
    });

    testWidgets('a failed Capture query renders an error, not a spinner',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x', title: 'Buy milk');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _captureHarness(db, capture: capture, captureStream: feed.stream),
      );
      feed.addError(Exception('watch failed'));
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // An error is not an absence — the row may well still be there.
      expect(find.byKey(const Key('clarify_subject_missing')), findsNothing);
    });

    testWidgets('a failed Outcome query renders an error, not a spinner',
        (tester) async {
      final todo = await _insertInboxTodo(db, id: 't', title: 'Buy milk');
      final feed = StreamController<Todo?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(
        _harness(db, todo: todo, todoStream: feed.stream),
      );
      feed.addError(Exception('watch failed'));
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('clarify_subject_missing')), findsNothing);
    });
  });

}
