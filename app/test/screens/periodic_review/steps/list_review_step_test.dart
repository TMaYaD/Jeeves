/// Widget tests for [ListReviewStep<Todo>] — the shared per-item-cursor
/// body extracted from the three Periodic Review list-driven steps.
///
/// These exercise the surface contract directly (load error / loading /
/// empty / current-item render / routing-then-advance) over an in-memory
/// [GtdDatabase]; the per-step files (`waiting_for_step.dart`,
/// `next_actions_step.dart`, `someday_maybe_step.dart`) have their own tests
/// for the step-specific axes (copy, include/except filters, dialog
/// modifier).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/periodic_review/steps/list_review_step.dart';
import 'package:jeeves/utils/snapshot_nav.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../../../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(
  GtdDatabase db, {
  required String id,
  String title = 'Sample task',
  String intent = 'next',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: Value(intent),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

/// Test harness: renders a [ListReviewStep<Todo>] inside a MaterialApp with
/// the in-memory database wired up. The caller owns the slice — pass an
/// explicit `nav`, `loadError`, `routings` — so each test exercises a
/// concrete combination of the surface contract.
Widget _harness({
  required GtdDatabase db,
  required SnapshotNav<Todo> nav,
  String? loadError,
  Map<int, RoutingKind> routings = const {},
  required ListReviewEmpty emptyState,
  String loadErrorTitle = "Couldn't load",
  String headline = 'Headline',
  Set<ProcessAction> processInclude = const {ProcessAction.keep},
  Set<ProcessAction> processExcept = const {},
  Map<ProcessAction, String> processLabels = const {},
  String? Function(Todo)? subtextFor,
  required VoidCallback onRetry,
  required void Function(int, RoutingKind) onRecordRouting,
  required VoidCallback onAdvance,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ListReviewStep<Todo>(
          nav: nav,
          loadError: loadError,
          routings: routings,
          headline: headline,
          processInclude: processInclude,
          processExcept: processExcept,
          processLabels: processLabels,
          emptyState: emptyState,
          loadErrorTitle: loadErrorTitle,
          subtextFor: subtextFor,
          onRetry: onRetry,
          onRecordRouting: onRecordRouting,
          onAdvance: onAdvance,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ListReviewStep — surface guards', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('renders the error surface with configured title and Retry',
        (tester) async {
      var retried = false;
      await tester.pumpWidget(_harness(
        db: db,
        nav: const SnapshotNav<Todo>(),
        loadError: 'boom',
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        loadErrorTitle: "Couldn't load Foo",
        onRetry: () => retried = true,
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.text("Couldn't load Foo"), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retried, isTrue);
    });

    testWidgets('renders a spinner while the snapshot is unloaded',
        (tester) async {
      await tester.pumpWidget(_harness(
        db: db,
        nav: const SnapshotNav<Todo>(),
        loadError: null,
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets(
        'renders the configured empty-state copy when the snapshot is empty',
        (tester) async {
      await tester.pumpWidget(_harness(
        db: db,
        nav: const SnapshotNav<Todo>(items: []),
        emptyState: const ListReviewEmpty(
          icon: Icons.hourglass_empty,
          title: 'No waiting-for items',
          subtitle: 'Tap Next to continue.',
        ),
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.text('No waiting-for items'), findsOneWidget);
      expect(find.text('Tap Next to continue.'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    });

    testWidgets(
        'renders the empty-state copy once the cursor consumes all items',
        (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      await tester.pumpWidget(_harness(
        db: db,
        // Cursor past the end => nav.isComplete is true.
        nav: SnapshotNav<Todo>(items: [todo], index: 1),
        emptyState: const ListReviewEmpty(
          icon: Icons.task_alt_outlined,
          title: 'All clear',
          subtitle: 'Tap Next to continue.',
        ),
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.text('All clear'), findsOneWidget);
    });
  });

  group('ListReviewStep — current-item render', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('renders the headline and current item title', (tester) async {
      final todo = await _insertTodo(db, id: 't1', title: 'My task');
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        headline: 'Still worth doing?',
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.text('Still worth doing?'), findsOneWidget);
      expect(find.text('My task'), findsOneWidget);
    });

    testWidgets('subtextFor renders the per-item subtext', (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        subtextFor: (t) => 'Subtext for ${t.id}',
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      expect(find.text('Subtext for t1'), findsOneWidget);
    });
  });

  group('ListReviewStep — routing + advance', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'Keep advances the cursor and does not record a routing',
        (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      var advances = 0;
      final recorded = <MapEntry<int, RoutingKind>>[];
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        // Default-on `nextActionDialog` modifier is not relevant here; Keep
        // is the action under test. The modifier itself is covered by the
        // dedicated group below.
        processInclude: const {ProcessAction.keep},
        processLabels: const {ProcessAction.keep: 'Keep on Test'},
        onRetry: () {},
        onRecordRouting: (i, k) => recorded.add(MapEntry(i, k)),
        onAdvance: () => advances++,
      ));

      await tester.tap(find.text('Keep on Test'));
      await tester.pumpAndSettle();

      expect(advances, 1);
      expect(recorded, isEmpty);
    });

    testWidgets(
        'a real routing (Trash) records into the configured collection '
        'then advances', (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      var advances = 0;
      final recorded = <MapEntry<int, RoutingKind>>[];
      await tester.pumpWidget(_harness(
        db: db,
        // Cursor at index=0, then advance.
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        processInclude: const {ProcessAction.keep},
        // Drop everything except Trash so the test taps unambiguously.
        processExcept: const {
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
          ProcessAction.done,
          ProcessAction.nextActionDialog,
        },
        onRetry: () {},
        onRecordRouting: (i, k) => recorded.add(MapEntry(i, k)),
        onAdvance: () => advances++,
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      // Routing recorded at the cursor index, then advance.
      expect(recorded, hasLength(1));
      expect(recorded.first.key, 0);
      expect(recorded.first.value, RoutingKind.trash);
      expect(advances, 1);

      // The routed write hit the DB.
      final row = await db.todoDao.getTodo('t1');
      expect(row?.intent, 'trash');
    });

    testWidgets(
        'routing record uses the live cursor index — '
        'second-item advance records at index 1', (tester) async {
      final todo1 = await _insertTodo(db, id: 't1');
      final todo2 = await _insertTodo(db, id: 't2');
      var advances = 0;
      final recorded = <MapEntry<int, RoutingKind>>[];
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo1, todo2], index: 1),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        processInclude: const {ProcessAction.keep},
        processExcept: const {
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
          ProcessAction.done,
          ProcessAction.nextActionDialog,
        },
        onRetry: () {},
        onRecordRouting: (i, k) => recorded.add(MapEntry(i, k)),
        onAdvance: () => advances++,
      ));

      await tester.tap(find.text('Trash'));
      await tester.pumpAndSettle();

      expect(recorded.single.key, 1,
          reason: 'routing must be recorded at the live cursor index');
      expect(advances, 1);
    });
  });

  group('ListReviewStep — previously-selected affordance', () {
    late GtdDatabase db;
    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets(
        'routings[index] surfaces as the lastAction on the action bar',
        (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        routings: const {0: RoutingKind.trash},
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        processInclude: const {ProcessAction.keep},
        processExcept: const {
          ProcessAction.next,
          ProcessAction.waitingFor,
          ProcessAction.someday,
          ProcessAction.done,
          ProcessAction.nextActionDialog,
        },
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      // The Trash button is rendered with the "previously selected"
      // affordance — a filled check_circle icon next to the label.
      final trashButton = find.ancestor(
        of: find.text('Trash'),
        matching: find.byType(OutlinedButton),
      );
      expect(trashButton, findsOneWidget);
      expect(
        find.descendant(
            of: trashButton, matching: find.byIcon(Icons.check_circle)),
        findsOneWidget,
        reason: 'previously-selected affordance is a filled check icon',
      );
    });
  });

  // The default-on `nextActionDialog` modifier turns the Next button into a
  // dialog opener; on Save, [ListReviewStep] re-reads the row and treats a
  // blank phrase as "no follow-through" — no routing recorded, cursor stays.
  // The phrase-backed path records `RoutingKind.nextAction` at the live
  // cursor index and advances. The per-step suites cover this via their own
  // wizard wiring; this group pins the behaviour at the shared widget.
  group('ListReviewStep — nextActionDialog modifier', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() async => db.close());

    testWidgets('tapping Next Action opens NextActionDialog', (tester) async {
      final todo = await _insertTodo(db, id: 't1');
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        onRetry: () {},
        onRecordRouting: (_, _) {},
        onAdvance: () {},
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(find.byType(NextActionDialog), findsOneWidget);
    });

    testWidgets(
        'phrase + Save writes next_action_text, records nextAction at the '
        'live cursor index, and advances', (tester) async {
      final todo1 = await _insertTodo(db, id: 't1', intent: 'maybe');
      final todo2 = await _insertTodo(db, id: 't2', intent: 'maybe');
      var advances = 0;
      final recorded = <MapEntry<int, RoutingKind>>[];
      await tester.pumpWidget(_harness(
        db: db,
        // Cursor on the second item so we also pin the "live cursor index"
        // contract for this path.
        nav: SnapshotNav<Todo>(items: [todo1, todo2], index: 1),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        onRetry: () {},
        onRecordRouting: (i, k) => recorded.add(MapEntry(i, k)),
        onAdvance: () => advances++,
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(NextActionDialog),
          matching: find.byType(TextField),
        ),
        'Draft the outline',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Dialog wrote the phrase and applied the routing.
      final row = await db.todoDao.getTodo('t2');
      expect(row?.intent, 'next');
      expect(row?.nextActionText, 'Draft the outline');

      // ListReviewStep recorded a nextAction routing at the live cursor and
      // advanced exactly once.
      expect(recorded, hasLength(1));
      expect(recorded.first.key, 1);
      expect(recorded.first.value, RoutingKind.nextAction);
      expect(advances, 1);
    });

    testWidgets(
        'blank Save re-reads the row, records no routing, and does not advance',
        (tester) async {
      final todo = await _insertTodo(db, id: 't1', intent: 'maybe');
      var advances = 0;
      final recorded = <MapEntry<int, RoutingKind>>[];
      await tester.pumpWidget(_harness(
        db: db,
        nav: SnapshotNav<Todo>(items: [todo]),
        emptyState: const ListReviewEmpty(
          icon: Icons.star_border,
          title: 'Empty',
          subtitle: 'Tap Next',
        ),
        onRetry: () {},
        onRecordRouting: (i, k) => recorded.add(MapEntry(i, k)),
        onAdvance: () => advances++,
      ));

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      // Leave the field empty — the dialog skips the write, so the row's
      // `next_action_text` stays null. ListReviewStep re-reads, sees blank,
      // and must neither record a routing nor advance the cursor.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final row = await db.todoDao.getTodo('t1');
      expect(row?.intent, 'maybe',
          reason: 'blank Save must not change the intent');
      expect(row?.nextActionText, isNull,
          reason: 'blank Save must not write a phrase');
      expect(recorded, isEmpty,
          reason: 'blank promotion must not record a routing');
      expect(advances, 0,
          reason: 'blank promotion must leave the cursor on the item');
    });
  });
}
