import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
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

/// Scrolls [label] into view and taps it.
///
/// The destination buttons sit below the fold on the 800x600 test surface, and
/// Skip sits below *them* as its own ListView child — far enough down that it
/// is not built at all until scrolled toward. Being built still isn't enough
/// to be tappable: a ListView builds children within its cacheExtent while
/// they remain below the viewport, and a tap at such a widget's centre
/// hit-tests empty space instead. Hence drag-until-built, then ensureVisible.
Future<void> _scrollAndTap(WidgetTester tester, String label) async {
  for (var i = 0; i < 15 && find.text(label).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(label), findsOneWidget,
      reason: 'the $label button never came into view');
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
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
  _RecordingClarificationService(this.inner);

  final ClarificationService inner;

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
    return inner.updateFields(
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
  Future<bool> exists(String id) => inner.exists(id);

  @override
  Future<Set<String>> getPersonTagIds(String id) =>
      inner.getPersonTagIds(id);

  @override
  Future<void> clarifyToOutcome(
    String id, {
    required RoutingKind to,
    String? nextActionText,
    Set<String>? personTagIds,
    String? userId,
  }) =>
      inner.clarifyToOutcome(
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
      inner.promoteCaptureToOutcome(id, intent: intent, dueDate: dueDate);

  @override
  Future<int> completeOutcome(String id) => inner.completeOutcome(id);

  @override
  Future<void> stampClarified(String id) => inner.stampClarified(id);

  @override
  Future<bool> captureExists(String captureId) =>
      inner.captureExists(captureId);

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
    return inner.clarifyCaptureToOutcome(
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
      inner.discardCapture(captureId, now: now);
}

/// A [ClarificationService] whose Capture-clarify write always fails, so the
/// screen's error path can be exercised against a real failure rather than a
/// simulated one.
class _FailingClarificationService extends _RecordingClarificationService {
  _FailingClarificationService(super.inner);

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
  }) =>
      Future<String>.error(StateError('write failed'));
}

/// A [ClarificationService] whose Capture-clarify write parks on [gate], so a
/// test can observe the UI mid-write.
class _BlockingClarificationService extends _RecordingClarificationService {
  _BlockingClarificationService(super.inner, this.gate);

  final Future<void> gate;

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
  }) async {
    await gate;
    return super.clarifyCaptureToOutcome(
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
}

/// Whether the Skip affordance is currently tappable.
bool _skipEnabled(WidgetTester tester) =>
    tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Skip'))
        .onPressed !=
    null;

/// Whether the app-bar back button is currently tappable.
bool _backEnabled(WidgetTester tester) =>
    tester
        .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_back_ios_new))
        .onPressed !=
    null;

/// Feeds [captureProvider] without subscribing to a live drift `watch()`.
///
/// The screen binds to the Capture live, so the stream behind that provider is
/// what a test uses to make the row change (or disappear) underneath an open
/// screen. A real `watch()` would leave drift's StreamQueryStore holding a
/// pending timer and hang `pumpAndSettle` (docs/TESTING.md), so tests write to
/// the database and then push the re-read row — or `null` for a delete — down
/// this controller themselves.
class _CaptureFeed {
  final _controller = StreamController<Capture?>.broadcast();

  Stream<Capture?> get stream => _controller.stream;

  /// Re-reads [captureId] from local storage and emits it, exactly as a live
  /// query would after a write lands.
  Future<void> emitFrom(GtdDatabase db, String captureId) async =>
      _controller.add(await db.captureDao.getCapture(captureId));

  /// The row is gone from local storage. That is the complete signal the UI
  /// gets — it carries no notion of *why* (ARCHITECTURE.md § two-stage
  /// boundary).
  void emitMissing() => _controller.add(null);

  Future<void> close() => _controller.close();
}

Widget _buildApp(
  GtdDatabase db,
  String captureId, {
  ClarificationService? clarificationService,
  List<Tag>? personTags,
  _CaptureFeed? captureFeed,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // The screen's live subject binding. Default to a one-shot read of the
      // stored row: enough for the screen to render, with no pending timer.
      captureProvider(captureId).overrideWith(
        (_) => captureFeed?.stream ??
            Stream.fromFuture(db.captureDao.getCapture(captureId)),
      ),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
      // Only the Waiting For flow opens the person picker. Override with a
      // single-value stream there so drift's StreamQueryStore (which leaves a
      // pending timer behind on dispose) is never subscribed to.
      if (personTags != null)
        personTagsProvider.overrideWith((ref) => Stream.value(personTags)),
    ],
    child: MaterialApp.router(
      routerConfig: GoRouter(
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

    testWidgets('Waiting For delegates the Capture and returns to the Inbox',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Ask Bob'));
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('alice'),
        name: const Value('Alice'),
        type: const Value('person'),
        userId: const Value(_userId),
      ));

      await tester.pumpWidget(_buildApp(
        db,
        'x',
        personTags: [
          Tag(id: 'alice', name: 'Alice', type: 'person', userId: _userId),
        ],
      ));
      await tester.pumpAndSettle();

      // Waiting For sits below the default 800x600 test viewport.
      await tester.ensureVisible(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Waiting For'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      // The picker's confirm is a FilledButton labelled "Done"; the route bar
      // carries its own "Done" — disambiguate by widget type.
      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await tester.pumpAndSettle();

      // The whole chain: the picker returns the selection, the routing write
      // carves the Outcome with the delegate attached, and only then does the
      // screen pop — so the Inbox is what the user lands on.
      final outcome = await _outcomeOf(db, 'x');
      expect(outcome, isNotNull);
      expect(
        await db.todoDao.getPersonTagIdsForTodo(outcome!.id),
        contains('alice'),
      );
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNotNull);
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('Maybe carves an Outcome with intent = maybe', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Learn guitar'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // The destination buttons are below the fold on the 800x600 test surface;
      // scroll them into view before tapping.
      await _scrollAndTap(tester, 'Someday');

      final outcome = await _outcomeOf(db, 'x');
      expect(outcome!.clarified, isTrue);
      expect(outcome.intent, 'maybe');
    });

    testWidgets('Done carves an already-achieved Outcome', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Old idea'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await _scrollAndTap(tester, 'Done');

      // Done records a Completion — the user finished the thing. It is not a
      // discard, so the Outcome must not land on the Trash List either.
      final outcome = (await _outcomeOf(db, 'x'))!;
      expect(outcome.doneAt, isNotNull);
      expect(outcome.intent, isNot('trash'));
    });

    testWidgets('Discard stamps the Capture and carves no Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Never worth it'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await _scrollAndTap(tester, 'Discard');

      // A discard is the zero-Outcome verdict: the clarify act completed, so
      // `clarified_at` is stamped and the item leaves the Inbox, but nothing
      // was ever worth creating.
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNotNull);
      expect(await _outcomeOf(db, 'x'), isNull);
      expect(await _inboxIds(db), isEmpty);
    });

    testWidgets('no discard-labelled action creates an Outcome',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Noise'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await _scrollAndTap(tester, 'Discard');

      // The bug this screen shipped with: a button that said "discard" wrote a
      // completed Outcome. Nothing may land in `todos` on this path — not even
      // a trashed row, because Trash is a List of Outcomes and a discarded
      // Capture never becomes one.
      expect(await db.select(db.todos).get(), isEmpty);
    });

    testWidgets('discarding an untitled Capture keeps its original title',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Half a thought'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_title')), '');
      await tester.pump();

      await _scrollAndTap(tester, 'Discard');

      // Discard stays enabled with a blank title so an unnamed fragment can be
      // thrown away — but the Capture is the provenance record of *what* was
      // discarded, so the blank must not be written over it.
      final capture = (await db.captureDao.getCapture('x'))!;
      expect(capture.clarifiedAt, isNotNull);
      expect(capture.title, 'Half a thought');
    });

    testWidgets('Skip leaves the Capture in the Inbox and carves nothing',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Deferred'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await _scrollAndTap(tester, 'Skip');

      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNull);
      expect(await _outcomeOf(db, 'x'), isNull);
      expect(await _inboxIds(db), ['x']);
    });

    testWidgets('Skip is disabled while a routing write is in flight',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      final gate = Completer<void>();
      await tester.pumpWidget(_buildApp(
        db,
        'x',
        clarificationService: _BlockingClarificationService(
          DaoClarificationService(db),
          gate.future,
        ),
      ));
      await tester.pumpAndSettle();

      // Skip is the last ListView child — drag until it is built.
      for (var i = 0; i < 15 && find.text('Skip').evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_skipEnabled(tester), isTrue);

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pump();

      // Skip sits outside the action bar, so it does not inherit the bar's
      // in-flight disabling. Left live, it would pop the screen mid-write and
      // skip the post-route text flush.
      expect(_skipEnabled(tester), isFalse);

      gate.complete();
      await tester.pumpAndSettle();
      expect(await _outcomeOf(db, 'x'), isNotNull);
    });

    testWidgets('every navigation escape is shut while a write is in flight',
        (tester) async {
      await db.captureDao.insertCapture(
        _captureCompanion(id: 'x', title: 'Buy milk'),
      );

      final gate = Completer<void>();
      await tester.pumpWidget(_buildApp(
        db,
        'x',
        clarificationService: _BlockingClarificationService(
          DaoClarificationService(db),
          gate.future,
        ),
      ));
      await tester.pumpAndSettle();

      // Edit the title so there is a pending Capture write to lose: the
      // routing verdict carries the new title into the Outcome, but the
      // Capture only catches up in `onAfterRoute`.
      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'New title');
      await tester.pump();
      expect(_backEnabled(tester), isTrue);

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pump();

      // The app-bar button and platform back are separate escapes from Skip;
      // either one popping here unmounts the screen before the text flush,
      // leaving the Capture's title behind the Outcome's.
      expect(_backEnabled(tester), isFalse);

      // Platform back is the escape no widget owns, so drive it for real
      // rather than reading `canPop` off the PopScope. Assert on the app-bar
      // title, not a ListView child: the `ensureVisible` above scrolled the
      // title field out of the cache extent, so it is no longer built.
      // `pumpAndSettle`, not `pump`: the pop is an animated route transition,
      // so a single frame leaves the outgoing screen still in the tree and the
      // assertion below would hold whether or not the guard did anything.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Clarify'), findsOneWidget,
          reason: 'system back must not pop the screen mid-write');

      gate.complete();
      await tester.pumpAndSettle();

      // Both writes landed, so the provenance record matches what the user
      // actually wrote.
      expect((await _outcomeOf(db, 'x'))!.title, 'New title');
      expect((await db.captureDao.getCapture('x'))!.title, 'New title');
    });

    testWidgets('empty title does not clarify the Capture', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Has title'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_title')), '');
      await tester.pump();

      await tester.tap(find.text('Next Action'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // An Outcome must be nameable, so the button is disabled and the tap is
      // a no-op: the Capture stays in the Inbox.
      expect(await _outcomeOf(db, 'x'), isNull);
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNull);
      expect(find.text('Title is required to process'), findsOneWidget);
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

    testWidgets('a failed write surfaces an error and does not pop',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(
        _buildApp(
          db,
          'x',
          clarificationService:
              _FailingClarificationService(DaoClarificationService(db)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // The action bar owns the tap handler, so it must report the failure
      // itself — otherwise the write escapes as an unhandled async error and
      // the tap looks like it did nothing.
      expect(find.text('Operation failed. Please try again.'), findsOneWidget);
      // And the screen stays put, so the user's edits are not lost.
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);
      expect(await _outcomeOf(db, 'x'), isNull);
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

  // The screen used to read its Capture exactly once and hold the snapshot for
  // its whole lifetime, so a row that changed underneath it was invisible and
  // got overwritten on the way out. It now binds to the row live (#427).
  group('InboxClarifyScreen — live subject binding', () {
    late GtdDatabase db;
    late _CaptureFeed feed;

    setUp(() {
      db = _openInMemory();
      feed = _CaptureFeed();
    });
    tearDown(() async {
      await feed.close();
      await db.close();
    });

    testWidgets('adopts a change to a field the user has not edited',
        (tester) async {
      await db.captureDao.insertCapture(
        _captureCompanion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      // The row changes in local storage. The screen cannot tell whether that
      // came from another screen, a background job or a replicated edit — the
      // changed row is the whole signal.
      await db.captureDao.updateFields('x', title: 'Buy oat milk');
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      final titleField =
          tester.widget<TextField>(find.byKey(const Key('clarify_title')));
      expect(titleField.controller?.text, 'Buy oat milk');
    });

    testWidgets('leaves a field the user is editing alone', (tester) async {
      await db.captureDao.insertCapture(
        _captureCompanion(id: 'x', title: 'Buy milk', notes: 'Full fat'),
      );

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Buy almond milk');
      await tester.pumpAndSettle();

      await db.captureDao.updateFields('x', title: 'Buy oat milk');
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      // Dirty field: the user's in-progress edit wins.
      final titleField =
          tester.widget<TextField>(find.byKey(const Key('clarify_title')));
      expect(titleField.controller?.text, 'Buy almond milk');
      // Clean field: the incoming notes land.
      final notesField =
          tester.widget<TextField>(find.byKey(const Key('clarify_notes')));
      expect(notesField.controller?.text, 'Full fat');
    });

    testWidgets('an incoming edit is not overwritten by the routing save',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      await db.captureDao.updateFields('x', title: 'Buy oat milk');
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      // The save on the way out must carry the row's current title, not the
      // one this screen happened to load with.
      expect((await db.captureDao.getCapture('x'))!.title, 'Buy oat milk');
      expect((await _outcomeOf(db, 'x'))!.title, 'Buy oat milk');
    });

    testWidgets('clearing notes persists after an intermediate save',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      // The intermediate save: notes reach the row while the screen is open.
      // Before #427 the screen's load-time snapshot still said "no notes", so
      // the subsequent clear computed `clearNotes: false` and the stale notes
      // survived as Capture provenance.
      await db.captureDao.updateFields('x', notes: 'Full fat');
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_notes')), '');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect((await db.captureDao.getCapture('x'))!.notes, isNull);
    });

    testWidgets('a subject that disappears stops being editable',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);

      // The row is gone from local storage.
      await db.captureDao.deleteCapture('x');
      feed.emitMissing();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('clarify_title')), findsNothing);
      expect(find.text('Next Action'), findsNothing);
      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
    });
  });
}
