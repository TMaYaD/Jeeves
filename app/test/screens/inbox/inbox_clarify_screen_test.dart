import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/daos/capture_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/clarification_service.dart';
import '../../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// A [CaptureDao] whose tag-hint read parks on [gate], so a test can hold the
/// hints back while the Capture watch resolves normally. Ordering those two
/// independently is the whole point: both are async, so without a gate the
/// pre-hint frame cannot be reached deterministically.
class _GatedCaptureDao extends CaptureDao {
  _GatedCaptureDao(super.db, this.gate);

  final Future<void> gate;

  @override
  Future<List<Tag>> tagHintsForCapture(String captureId) async {
    await gate;
    return super.tagHintsForCapture(captureId);
  }
}

/// A [CaptureDao] whose tag-hint read fails, standing in for the query throwing.
class _ThrowingHintCaptureDao extends CaptureDao {
  _ThrowingHintCaptureDao(super.db);

  @override
  Future<List<Tag>> tagHintsForCapture(String captureId) async {
    throw StateError('hint read failed');
  }
}

/// [GtdDatabase] handing out a failing-hint DAO.
class _ThrowingHintDb extends GtdDatabase {
  _ThrowingHintDb(super.e);

  late final CaptureDao _dao = _ThrowingHintCaptureDao(this);

  @override
  CaptureDao get captureDao => _dao;
}

/// [GtdDatabase] handing out the gated DAO. Everything else is the real thing.
class _GatedDb extends GtdDatabase {
  _GatedDb(super.e, Future<void> gate) : _gate = gate;

  final Future<void> _gate;

  late final CaptureDao _gatedDao = _GatedCaptureDao(this, _gate);

  @override
  CaptureDao get captureDao => _gatedDao;
}

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

/// Tag ids joined to [todoId]. Read with a plain `select` — awaiting a live
/// drift `watch()` inside `testWidgets` never completes (docs/TESTING.md).
Future<Set<String>> _tagIdsOf(GtdDatabase db, String todoId) async {
  final rows = await (db.select(db.todoTags)
        ..where((t) => t.todoId.equals(todoId)))
      .get();
  return {for (final r in rows) r.tagId};
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

class _PopCounter extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
    super.didPop(route, previousRoute);
  }
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
  List<Tag>? personTags,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      captureProvider(captureId).overrideWith(
        (_) => captureStream ?? db.captureDao.getCapture(captureId).asStream(),
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

    testWidgets(
        'no Outcome can be committed before the tag hints have loaded',
        (tester) async {
      // The hints ride the draft into `clarifyCaptureToOutcome`, so a route
      // that beats the hint read mints an Outcome carrying none of the tags the
      // Capture had — silently, with nothing on screen to suggest a loss. This
      // screen used to read the hints alongside the Capture behind one spinner;
      // binding the Capture to a watch left the two racing, so the four
      // Outcome-creating routes are gated on the hints settling.
      final gate = Completer<void>();
      final gatedDb = _GatedDb(NativeDatabase.memory(), gate.future);
      addTearDown(gatedDb.close);
      await gatedDb.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));
      await gatedDb.tagDao.upsertTag(const TagsCompanion(
        id: Value('ctx1'),
        name: Value('errands'),
        type: Value('context'),
        userId: Value(_userId),
      ));
      await gatedDb.captureDao.assignTagHint('x', 'ctx1', _userId);

      // The Capture watch resolves; only the hints are held.
      await tester.pumpWidget(_buildApp(gatedDb, 'x'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clarify_title')), findsOneWidget,
          reason: 'precondition: the card rendered, only hints are pending');

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      expect(await _outcomeOf(gatedDb, 'x'), isNull,
          reason: 'routing must not commit while the hints are still in '
              'flight — the Outcome would lose every tag hint');

      // Release the hints: the same tap now routes, carrying them.
      gate.complete();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final outcome = await _outcomeOf(gatedDb, 'x');
      expect(outcome, isNotNull, reason: 'and routing works once they land');
      final tagIds = await _tagIdsOf(gatedDb, outcome!.id);
      expect(tagIds, contains('ctx1'),
          reason: 'the hint seeded the Outcome rather than being dropped');
    });

    testWidgets('a failed tag-hint read still lets the user route',
        (tester) async {
      // The gate settles on failure as well as success. Hints are a seeding
      // nicety, not a precondition for clarifying, so a throwing read must
      // degrade to "route without them" — leaving the four Outcome routes
      // disabled forever would strand the user on an item they cannot process.
      final failingDb = _ThrowingHintDb(NativeDatabase.memory());
      addTearDown(failingDb.close);
      await failingDb.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(failingDb, 'x'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load this item's tags."), findsOneWidget,
          reason: 'and says so rather than failing silently');

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();

      final outcome = await _outcomeOf(failingDb, 'x');
      expect(outcome, isNotNull,
          reason: 'routing must not stay gated behind a hint read that failed');
      expect(await _tagIdsOf(failingDb, outcome!.id), isEmpty,
          reason: 'it simply carries no hints');
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
