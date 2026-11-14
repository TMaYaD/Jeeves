/// Integration journey (issues #447, #781): a write that is pending when its Outcome
/// is deleted from local storage must not land.
///
/// Drives the real `/task/:id` route over a real [GtdDatabase] that records the
/// ops it authors. Two walks: an edit still in the field when the row goes, and
/// a value chosen from a sheet that was opened before the row went.
///
/// Neither can pass on `main`: the screen's old latch only blocked the dispose
/// flush, and sheet callbacks wrote straight through to the DAO, authoring an op
/// (and, for tags and Actions, inserting rows) for the deleted Outcome.
library;

import 'package:drift/drift.dart' show innerJoin;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Intent, Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/intent.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/clarify_shared_widgets.dart'
    show kEstimateOptionsMinutes;
import 'package:jeeves/widgets/meta_chip.dart' show formatMinutesLabel;
import 'package:jeeves/widgets/tag_list.dart' show TagList;
import 'package:jeeves/widgets/tag_text.dart' show TagText;
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;

import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Unmounts the tree and lets the dispose flush's real I/O finish.
Future<void> unmountWhileFocused(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => pumpEventQueue());
}

void main() {
  setUpAll(configureSqliteForTests);

  group('Subject deleted mid-flight (journey)', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Buy milk', userId: _userId);
    });
    tearDown(() async => db.close());

    // Live row streams are stubbed (a Drift watch's zero-duration close timer
    // would outlive the test); every write still hits the real database. The
    // stubbed streams are fed from whatever the test seeded into that database
    // before opening, so the screen shows the affordance a site needs.
    Future<void> openRoute(WidgetTester tester) async {
      // Tall enough that the longest bottom sheet (status menu) fits.
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/inbox',
        routes: [
          GoRoute(
            path: '/inbox',
            builder: (_, _) => const Scaffold(body: Text('Inbox')),
          ),
          GoRoute(
            path: '/task/:id',
            builder: (_, state) =>
                TaskDetailScreen(todoId: state.pathParameters['id']!),
          ),
        ],
      );
      final seeded = (await tester.runAsync(() async {
        final assigned = await (db.select(db.tags).join([
          innerJoin(db.todoTags, db.todoTags.tagId.equalsExp(db.tags.id)),
        ])
              ..where(db.todoTags.todoId.equals('o1')))
            .map((row) => row.readTable(db.tags))
            .get();
        final allTags = await db.select(db.tags).get();
        return (
          todo: (await db.todoDao.getTodo('o1'))!,
          assigned: assigned,
          projects: allTags.where((t) => t.type == 'project').toList(),
          contexts: allTags.where((t) => t.type == 'context').toList(),
          current: await db.actionDao.getCurrentAction('o1'),
          planned: await db.actionDao.getPlannedActions('o1'),
        );
      }))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          databaseProvider.overrideWithValue(db),
          taskDetailTodoProvider('o1')
              .overrideWith((_) => Stream.value(seeded.todo)),
          taskTagsProvider('o1').overrideWith((_) => Stream.value(seeded.assigned)),
          capturesForOutcomeProvider('o1')
              .overrideWith((_) => Stream.value([])),
          currentActionProvider('o1')
              .overrideWith((_) => Stream.value(seeded.current)),
          plannedActionsProvider('o1')
              .overrideWith((_) => Stream.value(seeded.planned)),
          terminatedActionsProvider('o1')
              .overrideWith((_) => Stream.value(const [])),
          projectTagsProvider.overrideWith((_) => Stream.value(seeded.projects)),
          contextTagsProvider.overrideWith((_) => Stream.value(seeded.contexts)),
          contextTagsWithCountProvider.overrideWith((_) => Stream.value([
                for (final t in seeded.contexts)
                  TagWithCount(tag: t, count: 0),
              ])),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();
      router.push('/task/o1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The seeded streams deliver on a later microtask; let them render so
      // pickers snapshot the seeded lists and the Action controls exist.
      await tester.pumpAndSettle();
    }

    testWidgets('an edit in the field when the Outcome is deleted is dropped',
        (tester) async {
      await openRoute(tester);
      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      await tester.pump();

      await tester.runAsync(() => db.todoDao.deleteOutcome('o1'));
      capture.clear();
      await unmountWhileFocused(tester);

      expect(await tester.runAsync(() => db.todoDao.getTodo('o1')), isNull);
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    testWidgets('a value confirmed in a sheet opened before the delete is dropped',
        (tester) async {
      await openRoute(tester);
      await tester.tap(find.text('Energy'));
      await tester.pumpAndSettle();
      expect(find.text('Energy Level'), findsOneWidget);

      // The sheet is up; the row goes; then the user confirms.
      await tester.runAsync(() => db.todoDao.deleteOutcome('o1'));
      capture.clear();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());

      expect(capture.recorded, isEmpty);
      expect(await tester.runAsync(() => db.todoDao.getTodo('o1')), isNull);
      final orphans = await tester.runAsync(() async => [
            ...await (db.select(db.todoTags)
                  ..where((t) => t.todoId.equals('o1')))
                .get(),
            ...await (db.select(db.actions)
                  ..where((a) => a.outcomeId.equals('o1')))
                .get(),
          ]);
      expect(orphans, isEmpty);
    });

    // One journey per site #781 lists: open the sheet or dialog, delete the
    // Outcome underneath it, confirm. The write must be dropped, authoring no
    // op and leaving no row behind, and the surface must close as a cancel
    // without an error. These pin behaviour the shared write seam already
    // provides (#447); a red one is a site that reaches storage around it.
    final scenarios = <_DeletedMidFlightScenario>[
      _DeletedMidFlightScenario(
        name: 'status menu → Next',
        seed: () async {
          final tagId =
              await db.tagDao.findOrCreateTag('alice', 'person', _userId);
          await db.tagDao.assignTag('o1', tagId, _userId);
        },
        open: (tester) async {
          await tester.tap(find.byKey(const Key('status_pill')));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Next')),
      ),
      _DeletedMidFlightScenario(
        name: 'status menu → Someday',
        open: _openStatusMenu,
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Someday')),
      ),
      _DeletedMidFlightScenario(
        name: 'status menu → Done',
        open: _openStatusMenu,
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Done')),
      ),
      _DeletedMidFlightScenario(
        name: 'status menu → Trash',
        open: _openStatusMenu,
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Trash')),
      ),
      _DeletedMidFlightScenario(
        name: 'status menu → Next (from Someday)',
        seed: () => db.todoDao.setIntent('o1', Intent.maybe),
        open: _openStatusMenu,
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Next')),
      ),
      _DeletedMidFlightScenario(
        name: 'status menu → Restore (from Trash)',
        seed: () => db.todoDao.setIntent('o1', Intent.trash),
        open: _openStatusMenu,
        sheetMarker: find.text('Set Status'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Restore to Next')),
      ),
      _DeletedMidFlightScenario(
        name: 'context tag editor → assign',
        seed: () async {
          await db.tagDao.findOrCreateTag('office', 'context', _userId);
        },
        open: _openContextTagEditor,
        sheetMarker: find.text('Edit Context Tags'),
        closesSheet: false, // each tap is its own write; the editor has no confirm
        confirm: _tapFirstContextTag,
      ),
      _DeletedMidFlightScenario(
        name: 'context tag editor → remove',
        seed: () async {
          final tagId =
              await db.tagDao.findOrCreateTag('office', 'context', _userId);
          await db.tagDao.assignTag('o1', tagId, _userId);
        },
        open: _openContextTagEditor,
        sheetMarker: find.text('Edit Context Tags'),
        closesSheet: false,
        confirm: _tapFirstContextTag,
      ),
      _DeletedMidFlightScenario(
        name: 'time estimate sheet',
        open: (tester) async {
          await tester.tap(find.text('Time'));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Time Estimate'),
        confirm: (tester) async => tester.tap(find.widgetWithText(
            ListTile, formatMinutesLabel(kEstimateOptionsMinutes.first))),
      ),
      _DeletedMidFlightScenario(
        name: 'due-date picker',
        seed: () => db.todoDao.updateFields('o1', dueDate: DateTime(2030, 3, 15)),
        open: (tester) async {
          await tester.scrollUntilVisible(find.text('Mar 15, 2030'), 200,
              scrollable: find.byType(Scrollable).first);
          await tester.tap(find.text('Mar 15, 2030'));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.byType(DatePickerDialog),
        confirm: (tester) async => tester.tap(find.text('OK')),
      ),
      _DeletedMidFlightScenario(
        name: 'project picker → assign',
        seed: () async {
          await db.tagDao.findOrCreateTag('Roof', 'project', _userId);
        },
        open: (tester) async {
          await tester.tap(find.text('ADD PROJECT'));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Select project'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Roof')),
      ),
      _DeletedMidFlightScenario(
        name: 'project picker → remove',
        seed: () async {
          final tagId =
              await db.tagDao.findOrCreateTag('Roof', 'project', _userId);
          await db.tagDao.assignTag('o1', tagId, _userId);
        },
        open: (tester) async {
          await tester.tap(find.text('ROOF'));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Select project'),
        confirm: (tester) async =>
            tester.tap(find.widgetWithText(ListTile, 'Remove project')),
      ),
      _DeletedMidFlightScenario(
        name: 'action sheet → add planned',
        open: (tester) async {
          await tester.tap(find.byKey(const Key('plan_add_trigger')));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.byKey(const Key('plan_action_confirm')),
        confirm: (tester) async {
          await tester.enterText(
              find.byKey(const Key('plan_action_text')), 'Call the roofer');
          await tester.pump();
          await tester.tap(find.byKey(const Key('plan_action_confirm')));
        },
      ),
      _DeletedMidFlightScenario(
        name: 'action sheet → edit planned',
        seed: () => db.actionDao.addPlannedAction('o1', 'Call the roofer'),
        open: (tester) async {
          await tester.tap(find.text('Call the roofer'));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Edit planned action'),
        confirm: (tester) async {
          await tester.enterText(
              find.byKey(const Key('plan_action_text')), 'Call the other roofer');
          await tester.pump();
          await tester.tap(find.byKey(const Key('plan_action_confirm')));
        },
      ),
      _DeletedMidFlightScenario(
        name: 'action sheet → replace current',
        seed: () async {
          await db.actionDao.setCurrentAction('o1', 'Measure the roof');
          await db.actionDao.addPlannedAction('o1', 'Call the roofer');
        },
        open: (tester) async {
          final planned = (await tester
              .runAsync(() => db.actionDao.getPlannedActions('o1')))!;
          await tester.tap(find.byKey(Key('plan_promote_${planned.single.id}')));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Replace current action?'),
        confirm: (tester) async =>
            tester.tap(find.byKey(const Key('plan_replace_confirm'))),
      ),
      _DeletedMidFlightScenario(
        name: 'action sheet → abandon current',
        seed: () => db.actionDao.setCurrentAction('o1', 'Measure the roof'),
        open: (tester) async {
          await tester.tap(find.byKey(const Key('plan_abandon_button')));
          await tester.pumpAndSettle();
        },
        sheetMarker: find.text('Abandon this action?'),
        confirm: (tester) async =>
            tester.tap(find.byKey(const Key('plan_abandon_confirm'))),
      ),
    ];

    for (final scenario in scenarios) {
      testWidgets('${scenario.name}: confirming after the delete is dropped',
          (tester) async {
        await tester.runAsync(scenario.seed ?? () async {});
        await openRoute(tester);
        await scenario.open(tester);
        // Guard against passing for the wrong reason: the surface must really
        // be up before the Outcome goes.
        expect(scenario.sheetMarker, findsOneWidget);

        await tester.runAsync(() => db.todoDao.deleteOutcome('o1'));
        capture.clear();
        final tagRowsAfterDelete = await tester.runAsync(
            () => (db.select(db.todoTags)..where((t) => t.todoId.equals('o1')))
                .get());

        await scenario.confirm(tester);
        await settleWithRealAsync(tester);

        expect(capture.recorded, isEmpty);
        expect(await tester.runAsync(() => db.todoDao.getTodo('o1')), isNull);
        final tagRowsAfterConfirm = await tester.runAsync(
            () => (db.select(db.todoTags)..where((t) => t.todoId.equals('o1')))
                .get());
        expect(tagRowsAfterConfirm, hasLength(tagRowsAfterDelete!.length));
        final actionRows = await tester.runAsync(() =>
            (db.select(db.actions)..where((a) => a.outcomeId.equals('o1')))
                .get());
        expect(actionRows, isEmpty);
        expect(scenario.sheetMarker,
            scenario.closesSheet ? findsNothing : findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// One site of the task detail screen whose sheet or dialog confirms a write.
class _DeletedMidFlightScenario {
  _DeletedMidFlightScenario({
    required this.name,
    required this.open,
    required this.sheetMarker,
    required this.confirm,
    this.seed,
    this.closesSheet = true,
  });

  final String name;

  /// Puts real rows in the database before the screen opens.
  final Future<void> Function()? seed;

  /// Brings the sheet or dialog up.
  final Future<void> Function(WidgetTester tester) open;

  /// Finds something only the open sheet or dialog shows.
  final Finder sheetMarker;

  /// Confirms the value; the Outcome is already deleted when this runs.
  final Future<void> Function(WidgetTester tester) confirm;

  /// False for the context tag editor, which stays open after each tap.
  final bool closesSheet;
}

Future<void> _openStatusMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('status_pill')));
  await tester.pumpAndSettle();
}

Future<void> _openContextTagEditor(WidgetTester tester) async {
  await tester.tap(find.descendant(
      of: find.byType(TagList).first, matching: find.byIcon(Icons.add)));
  await tester.pumpAndSettle();
}

Future<void> _tapFirstContextTag(WidgetTester tester) async {
  await tester.tap(find
      .descendant(
          of: find.byKey(const Key('context_tag_picker_cloud')),
          matching: find.byType(TagText))
      .first);
}
