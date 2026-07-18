/// Widget tests for [PersonTagPickerSheet] (issue #429).
///
/// The sheet pops with the chosen ids and the caller acts on the result, so
/// these drive it through a caller that stores the result and then performs
/// its own navigation — the shape every real callsite has.
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
import 'package:jeeves/widgets/person_tag_picker.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Todo> _insertTodo(GtdDatabase db, {required String id}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: const Value('Task'),
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

Tag _personTag(String id, String name) => Tag(
      id: id,
      name: name,
      type: 'person',
      userId: _userId,
    );

/// What the caller observed when [showPersonTagPicker] returned.
class _Observed {
  Set<String>? result;
  bool called = false;

  /// Whether the caller's own route was the top route at the moment the
  /// result arrived — i.e. the sheet had already closed. This is the
  /// ordering contract: a caller must never navigate underneath an open
  /// sheet.
  bool? callerRouteWasCurrent;
}

/// A page that opens the picker and, on a non-null result, pops **its own**
/// route — the caller shape this issue is about.
class _CallerPage extends StatelessWidget {
  const _CallerPage({
    required this.observed,
    this.todoId,
    this.assignedPersonTagIds = const <String>{},
    this.requireSelection = false,
  });

  final _Observed observed;
  final String? todoId;
  final Set<String> assignedPersonTagIds;
  final bool requireSelection;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            final selected = await showPersonTagPicker(
              context,
              todoId: todoId,
              assignedPersonTagIds: assignedPersonTagIds,
              requireSelection: requireSelection,
            );
            if (!context.mounted) return;
            observed
              ..called = true
              ..result = selected
              ..callerRouteWasCurrent = ModalRoute.of(context)?.isCurrent;
            if (selected != null) Navigator.pop(context);
          },
          child: const Text('Waiting For'),
        ),
      ),
    );
  }
}

/// A [TaskDetailNotifier] whose write never completes until [gate] is
/// completed, so a test can hold the sheet in its committing state and drive
/// the system back gesture at it.
class _BlockingNotifier extends TaskDetailNotifier {
  _BlockingNotifier(GtdDatabase db, String todoId)
      : super(db: db, userId: _userId, todoId: todoId);

  final gate = Completer<void>();

  @override
  Future<void> setPersonTags(Set<String> tagIds) => gate.future;
}

/// Counts route pops so a test can assert how many routes came off the stack,
/// not merely which page is showing at the end.
class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

Widget _harness(
  GtdDatabase db, {
  required _Observed observed,
  String? todoId,
  Set<String> assignedPersonTagIds = const <String>{},
  bool requireSelection = false,
  List<Tag> personTags = const [],
  NavigatorObserver? observer,
  TaskDetailNotifier? notifier,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Single-value stream: drift's StreamQueryStore leaves a pending timer
      // behind on dispose, which fails the test.
      personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
      if (notifier != null && todoId != null)
        taskDetailNotifierProvider(todoId).overrideWithValue(notifier),
    ],
    child: MaterialApp(
      navigatorObservers: [?observer],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _CallerPage(
                    observed: observed,
                    todoId: todoId,
                    assignedPersonTagIds: assignedPersonTagIds,
                    requireSelection: requireSelection,
                  ),
                ),
              ),
              child: const Text('Open caller'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Walks from the harness root to an open picker.
Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('Open caller'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Waiting For'));
  await tester.pumpAndSettle();
}

/// The confirm button is a [FilledButton] labelled "Done"; the inline
/// "Add person" row renders its own [TextButton] "Cancel" alongside the
/// sheet's dismiss "Cancel". Disambiguate by widget type throughout.
Future<void> _tapDone(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Done'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  group('PersonTagPickerSheet — write mode', () {
    testWidgets('confirming returns the selection and writes the tags',
        (tester) async {
      await _insertTodo(db, id: 't1');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        todoId: 't1',
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await _tapDone(tester);

      expect(observed.result, {'alice'});
      expect(await db.todoDao.getPersonTagIdsForTodo('t1'), contains('alice'));
      // Attaching a delegate is a clarifying act, so it stamps.
      expect((await db.todoDao.getTodo('t1'))!.lastClarifiedAt, isNotNull);
    });

    testWidgets('a second Done tap cannot pop the caller\'s route',
        (tester) async {
      await _insertTodo(db, id: 't5');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();
      final popCounter = _PopCounter();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        todoId: 't5',
        personTags: [_personTag('alice', 'Alice')],
        observer: popCounter,
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      // Two taps inside one frame: the commit is in flight when the second
      // lands. Without the re-entrancy guard the second _confirm reaches its
      // own Navigator.pop and closes the caller's route underneath the sheet.
      final done = find.widgetWithText(FilledButton, 'Done');
      await tester.tap(done);
      await tester.tap(done, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Exactly two pops: the sheet closing itself, and the caller closing its
      // own route on the result. A third would mean the extra tap popped a
      // route that was never the sheet's to close.
      expect(popCounter.pops, 2);
      expect(observed.result, {'alice'});
      expect(find.text('Open caller'), findsOneWidget);
      expect(await db.todoDao.getPersonTagIdsForTodo('t5'), {'alice'});
    });

    testWidgets('deselecting a pre-assigned tag removes it', (tester) async {
      final todo = await _insertTodo(db, id: 't2');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      await db.tagDao.assignTag(todo.id, 'alice', _userId);
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        todoId: 't2',
        assignedPersonTagIds: const {'alice'},
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      // Pre-selected on open — tapping clears it.
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await _tapDone(tester);

      expect(observed.result, isEmpty);
      expect(await db.todoDao.getPersonTagIdsForTodo('t2'), isEmpty);
    });

    testWidgets('cancelling returns null and writes nothing', (tester) async {
      await _insertTodo(db, id: 't3');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        todoId: 't3',
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(observed.called, isTrue);
      expect(observed.result, isNull);
      expect(await db.todoDao.getPersonTagIdsForTodo('t3'), isEmpty);
    });
  });

  group('PersonTagPickerSheet — selection-only mode', () {
    testWidgets('confirming returns the selection and writes nothing',
        (tester) async {
      await _insertTodo(db, id: 't4');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await _tapDone(tester);

      expect(observed.result, {'alice'});
      // No todoId was given, so nothing may have been attached to anything.
      expect(await db.select(db.todoTags).get(), isEmpty);
    });

    testWidgets('cancelling returns null and writes nothing', (tester) async {
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(observed.called, isTrue);
      expect(observed.result, isNull);
      expect(await db.select(db.todoTags).get(), isEmpty);
    });
  });

  group('PersonTagPickerSheet — contract', () {
    testWidgets('requireSelection disables Done until someone is selected',
        (tester) async {
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        requireSelection: true,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);

      final done = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Done'),
      );
      expect(done.onPressed, isNull);
    });

    testWidgets('the sheet is closed before the caller sees the result',
        (tester) async {
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await _tapDone(tester);

      // The sheet had already popped when the caller resumed, so the
      // caller's own pop closed the caller's route — not the sheet.
      expect(observed.callerRouteWasCurrent, isTrue);
      expect(find.byType(PersonTagPickerSheet), findsNothing);
      expect(find.text('Open caller'), findsOneWidget);
    });

    testWidgets('system back dismisses the sheet and yields no selection',
        (tester) async {
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        personTags: [_personTag('alice', 'Alice')],
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      // The platform back gesture, not the Cancel button: PopScope is the only
      // thing standing between it and the route, so it needs its own test.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(PersonTagPickerSheet), findsNothing);
      expect(observed.called, isTrue);
      expect(observed.result, isNull,
          reason: 'a dismissed sheet is a cancel — nothing was confirmed');
      expect(await db.select(db.todoTags).get(), isEmpty);
    });

    testWidgets('system back cannot dismiss the sheet mid-commit',
        (tester) async {
      await _insertTodo(db, id: 't6');
      await _insertPersonTag(db, id: 'alice', name: 'Alice');
      final observed = _Observed();
      final blocking = _BlockingNotifier(db, 't6');

      await tester.pumpWidget(_harness(
        db,
        observed: observed,
        todoId: 't6',
        personTags: [_personTag('alice', 'Alice')],
        notifier: blocking,
      ));
      await _openPicker(tester);
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      // Done starts the write, which hangs on the gate — the sheet is now
      // committing, so PopScope.canPop is false.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pump();

      // Dismissing here would hand the caller a null while the write it
      // asked for is still in flight.
      expect(find.byType(PersonTagPickerSheet), findsOneWidget);
      expect(observed.called, isFalse);

      // Releasing the write lets the sheet finish the way it always would.
      blocking.gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(PersonTagPickerSheet), findsNothing);
      expect(observed.result, {'alice'});
    });
  });
}
