import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/clarification_service.dart';
import '../../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

// Use 'local' to match CurrentUserIdNotifier's default build() value.
const _userId = 'local';

TodosCompanion _companion({
  required String id,
  required String title,
  String? notes,
  String? energyLevel,
  int? timeEstimate,
}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    notes: notes != null ? Value(notes) : const Value.absent(),
    energyLevel:
        energyLevel != null ? Value(energyLevel) : const Value.absent(),
    timeEstimate:
        timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

/// An Inbox Capture: `clarified_at` NULL. Captures carry only title and
/// notes — energy, time estimate and due date are Outcome attributes the
/// clarify card collects as draft state (ADR-0006).
CapturesCompanion _captureCompanion({
  required String id,
  required String title,
  String? notes,
}) {
  final now = DateTime.now();
  return CapturesCompanion(
    id: Value(id),
    title: Value(title),
    notes: notes != null ? Value(notes) : const Value.absent(),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

/// The Outcome a Capture was clarified into, via the provenance link.
Future<Todo?> _outcomeOf(GtdDatabase db, String captureId) async {
  final ids = await db.captureDao.outcomeIdsForCapture(captureId);
  if (ids.isEmpty) return null;
  return db.todoDao.getTodo(ids.single);
}

/// Ids still in the Inbox, read with a plain select — awaiting a live drift
/// `watch()` inside `testWidgets` never completes under the test binding's
/// clock.
Future<List<String>> _inboxIds(GtdDatabase db) async {
  final rows = await (db.select(db.captures)
        ..where((c) => c.clarifiedAt.isNull()))
      .get();
  return [for (final r in rows) r.id];
}

/// Delegates every [ClarificationService] call to a real
/// [DaoClarificationService] while recording the clear flags the last
/// [updateFields] call carried, so tests can assert the screen never sends a
/// spurious clear for a field that had no value.
class _RecordingClarificationService implements ClarificationService {
  _RecordingClarificationService(this._inner);

  final ClarificationService _inner;

  bool? lastClearNotes;
  bool? lastClearEnergyLevel;
  bool? lastClearTimeEstimate;
  bool? lastClearDueDate;

  /// Draft attributes the screen passed into [clarifyCaptureToOutcome]. The
  /// screen no longer routes text edits through [updateFields] — a Capture's
  /// title/notes go to CaptureDao — so this is where the "no spurious values"
  /// contract is now observable.
  String? lastNotes;
  String? lastEnergyLevel;
  int? lastTimeEstimate;
  DateTime? lastDueDate;

  @override
  Future<void> updateFields(
    String id, {
    String? title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    bool clearNotes = false,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    bool clearDueDate = false,
  }) {
    lastClearNotes = clearNotes;
    lastClearEnergyLevel = clearEnergyLevel;
    lastClearTimeEstimate = clearTimeEstimate;
    lastClearDueDate = clearDueDate;
    return _inner.updateFields(
      id,
      title: title,
      notes: notes,
      energyLevel: energyLevel,
      timeEstimate: timeEstimate,
      dueDate: dueDate,
      clearNotes: clearNotes,
      clearEnergyLevel: clearEnergyLevel,
      clearTimeEstimate: clearTimeEstimate,
      clearDueDate: clearDueDate,
    );
  }

  @override
  Future<bool> exists(String id) => _inner.exists(id);

  @override
  Future<Set<String>> getPersonTagIds(String id) =>
      _inner.getPersonTagIds(id);

  @override
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      _inner.clarifyToOutcome(
        id,
        to: to,
        nextActionText: nextActionText,
        personTagIds: personTagIds,
        userId: userId,
      );

  @override
  Future<int> promoteCaptureToOutcome(
    String id, {
    String? intent,
    DateTime? dueDate,
  }) =>
      _inner.promoteCaptureToOutcome(id, intent: intent, dueDate: dueDate);

  @override
  Future<int> completeOutcome(String id) => _inner.completeOutcome(id);

  @override
  Future<void> stampClarified(String id) => _inner.stampClarified(id);

  @override
  Future<bool> captureExists(String captureId) =>
      _inner.captureExists(captureId);

  @override
  Future<String> clarifyCaptureToOutcome(
    String captureId, {
    required RoutingKind to,
    required String userId,
    required String title,
    String? notes,
    String? energyLevel,
    int? timeEstimate,
    DateTime? dueDate,
    String? nextActionText,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) {
    lastNotes = notes;
    lastEnergyLevel = energyLevel;
    lastTimeEstimate = timeEstimate;
    lastDueDate = dueDate;
    return _inner.clarifyCaptureToOutcome(
        captureId,
        to: to,
        userId: userId,
        title: title,
        notes: notes,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        dueDate: dueDate,
        nextActionText: nextActionText,
        personTagIds: personTagIds,
        tagIds: tagIds,
        outcomeId: outcomeId,
        now: now,
      );
  }

  @override
  Future<void> discardCapture(String captureId, {DateTime? now}) =>
      _inner.discardCapture(captureId, now: now);
}

class _PopCounter extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
}

Widget _buildApp(
  GtdDatabase db,
  String captureId, {
  ClarificationService? clarificationService,
  // Feeds the screen's subject watch. Defaults to a one-shot read of the row
  // rather than the real `watchCapture()`: a live drift `watch()` keeps
  // `StreamQueryStore` emitting on every `notifyCapturesViewWrite`, so
  // `pumpAndSettle` never reaches a quiet frame and hangs the isolate hard
  // enough that the per-test timeout can't fire. Tests that need to *drive*
  // the watch (a delete under the open screen) pass their own controller.
  Stream<Capture?>? captureStream,
  NavigatorObserver? popObserver,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      captureProvider(captureId).overrideWith(
        (_) => captureStream ?? db.captureDao.getCapture(captureId).asStream(),
      ),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
    ],
    child: MaterialApp.router(
      routerConfig: GoRouter(
        observers: [?popObserver],
        // Nest the clarify route under /inbox so pop() has a page to return to.
        initialLocation: '/inbox/$captureId/clarify',
        routes: [
          GoRoute(
            path: '/inbox',
            builder: (context, _) => const Scaffold(body: Text('Inbox')),
            routes: [
              GoRoute(
                path: ':id/clarify',
                builder: (context, state) => InboxClarifyScreen(
                  captureId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxClarifyScreen', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    testWidgets('displays Capture title and notes pre-populated',
        (tester) async {
      await db.captureDao.insertCapture(
        _captureCompanion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      final titleField =
          tester.widget<TextField>(find.byKey(const Key('clarify_title')));
      final notesField =
          tester.widget<TextField>(find.byKey(const Key('clarify_notes')));
      expect(titleField.controller?.text, 'Buy milk');
      expect(notesField.controller?.text, 'Full fat');
    });

    testWidgets('Next Action carves a linked Outcome and stamps the Capture',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Clarifying creates an Outcome rather than flipping a column, and the
      // link back to the Capture is the provenance record (ADR-0006).
      final outcome = await _outcomeOf(db, 'x');
      expect(outcome, isNotNull);
      expect(outcome!.clarified, isTrue);
      expect(outcome.title, 'Buy milk');
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNotNull);
    });

    testWidgets('Next Action leaves the Inbox empty', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(await _inboxIds(db), isEmpty);
    });

    testWidgets('Maybe carves an Outcome with intent = maybe', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Learn guitar'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // The destination buttons are below the fold on the 800x600 test surface;
      // scroll them into view before tapping.
      await tester.ensureVisible(find.text('Maybe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maybe'));
      await tester.pumpAndSettle();

      final outcome = await _outcomeOf(db, 'x');
      expect(outcome!.clarified, isTrue);
      expect(outcome.intent, 'maybe');
    });

    testWidgets('Done (discard) carves an already-achieved Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Old idea'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Done (discard)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done (discard)'));
      await tester.pumpAndSettle();

      expect((await _outcomeOf(db, 'x'))!.doneAt, isNotNull);
    });

    testWidgets('Skip leaves the Capture in the Inbox and carves nothing',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Deferred'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNull);
      expect(await _outcomeOf(db, 'x'), isNull);
      expect(await _inboxIds(db), ['x']);
    });

    testWidgets('empty title does not clarify the Capture', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Has title'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_title')), '');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // An Outcome must be nameable, so the route is blocked and the Capture
      // stays in the Inbox.
      expect(await _outcomeOf(db, 'x'), isNull);
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNull);
    });

    testWidgets('edited title lands on both the Capture and the Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Old title'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'New title');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await _outcomeOf(db, 'x'))!.title, 'New title');
      // The edit is also kept on the Capture, so the provenance trail shows
      // what the user actually wrote rather than the original fragment.
      expect((await db.captureDao.getCapture('x'))!.title, 'New title');
    });

    testWidgets('energy chosen on the card lands on the new Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // A Capture has no energy column — the card collects it as draft state
      // and clarifyCaptureToOutcome writes it onto the Outcome it creates.
      await tester.ensureVisible(find.text('High'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await _outcomeOf(db, 'x'))!.energyLevel, 'high');
    });

    testWidgets('time estimate chosen on the card lands on the new Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('30m'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30m'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await _outcomeOf(db, 'x'))!.timeEstimate, 30);
    });

    testWidgets('deleting notes clears them on the Capture and the Outcome',
        (tester) async {
      await db.captureDao.insertCapture(
        _captureCompanion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_notes')), '');
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await db.captureDao.getCapture('x'))!.notes, isNull);
      expect((await _outcomeOf(db, 'x'))!.notes, isNull);
    });

    testWidgets('clarifying an untouched Capture invents no attributes',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      final recorder =
          _RecordingClarificationService(DaoClarificationService(db));
      await tester.pumpWidget(
        _buildApp(db, 'x', clarificationService: recorder),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // Nothing was entered, so nothing may be fabricated into the Outcome.
      expect(recorder.lastNotes, isNull);
      expect(recorder.lastEnergyLevel, isNull);
      expect(recorder.lastTimeEstimate, isNull);
      expect(recorder.lastDueDate, isNull);

      final outcome = (await _outcomeOf(db, 'x'))!;
      expect(outcome.energyLevel, isNull);
      expect(outcome.timeEstimate, isNull);
      expect(outcome.notes, isNull);
      expect(outcome.dueDate, isNull);
      expect(outcome.clarified, isTrue);
    });
  });

  group('InboxClarifyScreen — Capture deleted while open (#428)', () {
    late GtdDatabase db;
    late StreamController<Capture?> subject;

    setUp(() {
      db = _openInMemory();
      // Broadcast: the screen's provider is autoDispose, so a pop can drop
      // and re-create it — a single-subscription stream would throw
      // "already been listened to" on the re-listen.
      subject = StreamController<Capture?>.broadcast();
    });
    tearDown(() async {
      await subject.close();
      await db.close();
    });

    testWidgets('no emission yet renders a spinner', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(
        _buildApp(db, 'x', captureStream: subject.stream),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('This item is no longer in your Inbox'), findsNothing);
    });

    testWidgets(
        'a hard-delete under the open screen reaches the missing state, '
        'not an indefinite spinner', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));
      final capture = (await db.captureDao.getCapture('x'))!;

      await tester.pumpWidget(
        _buildApp(db, 'x', captureStream: subject.stream),
      );
      subject.add(capture);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);

      // Another device deletes the Capture; PowerSync applies it locally and
      // `watchSingleOrNull()` emits null.
      await db.captureDao.deleteCapture('x');
      subject.add(null);
      await tester.pumpAndSettle();

      expect(find.text('This item is no longer in your Inbox'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('clarify_title')), findsNothing);
    });

    testWidgets('the missing state offers a way back to the Inbox',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(
        _buildApp(db, 'x', captureStream: subject.stream),
      );
      subject.add(null);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back to Inbox'));
      await tester.pumpAndSettle();

      // Popped back onto the Inbox route rather than dead-ending.
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('a double-tapped escape pops once, not past the Inbox',
        (tester) async {
      // An invariant guard, not a reproduction: Navigator already absorbs the
      // second pop against a route that is mid-transition, so this holds with
      // or without the CTA's latch today. It pins "the escape pops exactly
      // once" so that stops being accidental — the moment this CTA does
      // anything beyond popping, the latch is what keeps it true.
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      final popCounter = _PopCounter();
      await tester.pumpWidget(
        _buildApp(db, 'x',
            captureStream: subject.stream, popObserver: popCounter),
      );
      subject.add(null);
      await tester.pumpAndSettle();

      // Both taps land before any rebuild can tear the route down.
      await tester.tap(find.text('Back to Inbox'));
      await tester.tap(find.text('Back to Inbox'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(popCounter.pops, 1, reason: 'the escape must pop exactly once');
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('an errored watch renders friendly copy, not the exception',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(
        _buildApp(db, 'x', captureStream: subject.stream),
      );
      subject.addError(Exception('SecretInternalDetail'));
      // Bounded pumping, not pumpAndSettle: the error branch logs the detail
      // through `debugPrint`, whose throttle timer keeps the binding from ever
      // reaching a quiet frame.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('This item is no longer in your Inbox'), findsNothing);
    });
  });

  // The null = no-change contract: updateFields with no fields and no clear
  // flags must not stamp last_clarified_at. The widget "untouched" test can't
  // observe this because routing stamps the column afterwards, so assert it
  // directly against the service.
  group('DaoClarificationService.updateFields no-spurious-write contract', () {
    late GtdDatabase db;

    setUp(() => db = _openInMemory());
    tearDown(() => db.close());

    test('a no-op updateFields does not stamp last_clarified_at', () async {
      await db.inboxDao.insertTodo(_companion(id: 'x', title: 'Buy milk'));
      final service = DaoClarificationService(db);

      await service.updateFields('x');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.lastClarifiedAt, isNull);
    });

    test('clearNotes nulls the column and stamps', () async {
      await db.inboxDao.insertTodo(
        _companion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );
      final service = DaoClarificationService(db);

      await service.updateFields('x', clearNotes: true);

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.notes, isNull);
      expect(row.lastClarifiedAt, isNotNull);
    });
  });
}
