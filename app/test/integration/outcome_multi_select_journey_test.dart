/// Journey: long-press an Outcome on a list page, select several, and apply a
/// bulk Project, Tag and status change — against a real database and a
/// recording op-capture seam.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/done/done_screen.dart';
import 'package:jeeves/screens/next/next_screen.dart';
import 'package:jeeves/screens/trash/trash_screen.dart';
import 'package:jeeves/screens/waiting_for/waiting_for_screen.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/widgets/dotted_add_button.dart';
import 'package:jeeves/widgets/tag_list.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// A Drift query awaited directly inside `testWidgets` waits on a clock that
/// never ticks (docs/TESTING.md), so reads go through a real-async turn.
Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async =>
    (await tester.runAsync(body)) as T;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;
  late String lastRoute;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    final seedTime = DateTime.utc(2026, 7, 28, 9);
    for (final id in ['o1', 'o2', 'o3']) {
      await db.todoDao.insertOutcome(
          id: id, title: 'Outcome $id', userId: 'local', now: seedTime);
      await db.todoDao.applyRouting(id,
          to: RoutingKind.nextAction, now: seedTime);
    }
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('home'),
        name: Value('home'),
        type: Value('context'),
        userId: Value('local')));
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('proj'),
        name: Value('Garden'),
        type: Value('project'),
        userId: Value('local')));
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('sam'),
        name: Value('Sam'),
        type: Value('person'),
        userId: Value('local')));
    capture.clear();
  });
  tearDown(() async => db.close());

  Future<void> pumpApp(WidgetTester tester,
      {String start = '/next', bool shell = false}) async {
    lastRoute = start;
    final router = GoRouter(
      initialLocation: start,
      routes: [
        ShellRoute(
          builder: (_, _, child) =>
              shell ? Scaffold(body: child) : child,
          routes: [
            GoRoute(path: '/next', builder: (_, _) => const NextScreen()),
            GoRoute(path: '/done', builder: (_, _) => const DoneScreen()),
            GoRoute(path: '/trash', builder: (_, _) => const TrashScreen()),
            GoRoute(
                path: '/waiting-for',
                builder: (_, _) => const WaitingForScreen()),
          ],
        ),
        GoRoute(
          path: '/task/:id',
          builder: (_, state) {
            lastRoute = '/task/${state.pathParameters['id']}';
            return Scaffold(body: Text('detail ${state.pathParameters['id']}'));
          },
        ),
      ],
    );
    final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _settle(tester);
  }

  Future<Set<String>> tagIdsOf(WidgetTester tester, String todoId) =>
      _real(tester, () async {
        final rows = await (db.select(db.todoTags)
              ..where((tt) => tt.todoId.equals(todoId)))
            .get();
        return {for (final r in rows) r.tagId};
      });

  Future<Todo> row(WidgetTester tester, String id) => _real(
      tester,
      () => (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle());

  testWidgets('select, set Project, add and remove a Tag, set status Someday',
      (tester) async {
    await pumpApp(tester);
    final before = await row(tester, 'o1');

    // Long-press enters selection with that Outcome; a tap toggles another and
    // does not navigate.
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Outcome o2'));
    await _settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    expect(lastRoute, '/next');

    // Set Project.
    await tester.tap(find.text('Project'));
    await _settle(tester);
    await tester.tap(find.text('Garden'));
    await _settle(tester);
    expect(await tagIdsOf(tester, 'o1'), {'proj'});
    expect(await tagIdsOf(tester, 'o2'), {'proj'});
    expect(await tagIdsOf(tester, 'o3'), isEmpty);
    final afterOrganising = await row(tester, 'o1');
    expect(afterOrganising.lastClarifiedAt, before.lastClarifiedAt);
    expect(afterOrganising.updatedAt, before.updatedAt);
    expect(capture.forCollection(todosCollection), isEmpty);
    expect(find.text('2 selected'), findsOneWidget);

    // Add a Tag, then remove it.
    await tester.tap(find.text('Tags'));
    await _settle(tester);
    // The + opens the cloud; tapping a Tag there applies it to every selected
    // Outcome, and it then shows as an applied chip (tap removes it).
    await tester.tap(find.byType(DottedAddButton));
    await _settle(tester);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('context_tag_picker_cloud')),
        matching: find.byKey(const Key('tag_chip_home'))));
    await _settle(tester);
    expect(await tagIdsOf(tester, 'o1'), {'proj', 'home'});
    expect(await tagIdsOf(tester, 'o2'), {'proj', 'home'});
    await tester.tap(find.descendant(
        of: find.byType(TagList).first,
        matching: find.byKey(const Key('tag_chip_home'))));
    await _settle(tester);
    expect(await tagIdsOf(tester, 'o1'), {'proj'});
    final tombstone = capture
        .forCollection(todoTagsCollection)
        .where((op) => op.tombstone && op.entityId == todoTagIdFor('o1', 'home'));
    expect(tombstone, hasLength(1));
    expect(capture.forCollection(todosCollection), isEmpty);
    await tester.tapAt(const Offset(5, 5)); // dismiss the sheet
    await _settle(tester);

    // Set status Someday: one todos op per Outcome, o3 untouched.
    capture.clear();
    await tester.tap(find.text('Status'));
    await _settle(tester);
    await tester.tap(find.text('Someday/Maybe'));
    await _settle(tester);
    expect((await row(tester, 'o1')).intent, 'maybe');
    expect((await row(tester, 'o2')).intent, 'maybe');
    expect((await row(tester, 'o3')).intent, 'next');
    expect(
        {for (final op in capture.forCollection(todosCollection)) op.entityId},
        {'o1', 'o2'});
    // Both left the Next list, so the mode is over.
    expect(find.textContaining('selected'), findsNothing);
    expect(find.text('Outcome o3'), findsOneWidget);
  });

  testWidgets('deselecting the last Outcome exits; back exits', (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.textContaining('selected'), findsNothing);

    await tester.longPress(find.text('Outcome o2'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.textContaining('selected'), findsNothing);
    expect(find.text('Outcome o2'), findsOneWidget);
  });

  testWidgets('long-press on a Waiting For row enters selection',
      (tester) async {
    await db.tagDao.assignTag('o1', 'sam', 'local');
    await pumpApp(tester, start: '/waiting-for');
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('back exits selection under a ShellRoute', (tester) async {
    await pumpApp(tester, shell: true);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('the bar keeps count and all actions usable at 320 px',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('1 selected'), findsOneWidget);
    for (final label in ['Project', 'Tags', 'Status', 'Select all']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a Project picker outliving its selection writes nothing',
      (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    await tester.tap(find.text('Project'));
    await _settle(tester);
    // Sync removes the only selected Outcome underneath the open picker.
    await _real(tester, () => db.todoDao.deleteOutcome('o1'));
    await _settle(tester);
    capture.clear();
    await tester.tap(find.text('Garden'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(await tagIdsOf(tester, 'o1'), isEmpty);
    expect(capture.recorded, isEmpty);
  });

  testWidgets('creating a New project after the selection vanished writes nothing',
      (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    await tester.tap(find.text('Project'));
    await _settle(tester);
    await tester.tap(find.text('New project'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Fresh');
    // Sync removes the only selected Outcome, disposing the picker, while
    // the dialog is still open.
    await _real(tester, () => db.todoDao.deleteOutcome('o1'));
    await _settle(tester);
    capture.clear();
    await tester.tap(find.text('Create'));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(await tagIdsOf(tester, 'o1'), isEmpty);
    expect(capture.forCollection(todoTagsCollection), isEmpty);
  });

  testWidgets('navigating away while a status batch writes does not throw',
      (tester) async {
    await pumpApp(tester);
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    await tester.tap(find.text('Status'));
    await _settle(tester);
    await tester.tap(find.text('Someday/Maybe'));
    await tester.pump();
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/done');
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Trash list offers no selection', (tester) async {
    await _real(tester, () => db.todoDao.applyRouting('o1',
        to: RoutingKind.trash, now: DateTime.utc(2026, 7, 29, 9)));
    await pumpApp(tester, start: '/trash');
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('the Done list offers no selection', (tester) async {
    await _real(tester, () => db.todoDao.applyRouting('o1',
        to: RoutingKind.done, now: DateTime.utc(2026, 7, 29, 9)));
    await pumpApp(tester, start: '/done');
    await tester.longPress(find.text('Outcome o1'));
    await _settle(tester);
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('an Outcome under two people counts once', (tester) async {
    await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('kim'),
        name: Value('Kim'),
        type: Value('person'),
        userId: Value('local')));
    await db.tagDao.assignTag('o1', 'sam', 'local');
    await db.tagDao.assignTag('o1', 'kim', 'local');
    await pumpApp(tester, start: '/waiting-for');
    await tester.longPress(find.text('Outcome o1').first);
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
  });
}
