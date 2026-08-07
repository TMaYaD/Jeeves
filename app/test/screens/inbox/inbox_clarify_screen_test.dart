import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/widgets/clarify_shared_widgets.dart';
import 'package:jeeves/widgets/next_action_dialog.dart';
import 'package:jeeves/widgets/state_surfaces.dart';
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

/// An Outcome's **raw** `energy_level` / `time_estimate` columns.
///
/// Deliberately a raw `select(db.todos)` and never [_outcomeOf] / `getTodo`:
/// those carry the D2 projection, which COALESCEs the *current Action's* value
/// over the column. A claim about what the column holds, read through the
/// projection, would resolve on the Action's own value and pass whether or not
/// the column was ever written — unfalsifiable.
Future<({String? energy, int? time})> _rawEffortColumns(
  GtdDatabase db,
  String outcomeId,
) async {
  final row = await (db.select(db.todos)..where((t) => t.id.equals(outcomeId)))
      .getSingle();
  return (energy: row.energyLevel, time: row.timeEstimate);
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

/// Confirms [NextActionDialog] with whatever phrase it opened seeded with.
///
/// The clarify card leaves the default-on `nextActionDialog` modifier on for a
/// Capture (#689), so Next opens the dialog before anything is written.
/// Accepting the seed is what reproduces the pre-#689 title-as-action result,
/// which is what every test below that is *about something else* wants.
Future<void> _acceptNextActionDialog(WidgetTester tester) async {
  expect(find.byType(NextActionDialog), findsOneWidget,
      reason: 'Next on a Capture opens the dialog before it writes anything');
  await tester.tap(find.text('Save'));
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

/// A [ClarificationService] whose Capture-clarify write always fails, so the
/// screen's error path can be exercised against a real failure rather than a
/// simulated one.
///
/// **Extends** the real [DaoClarificationService] rather than implementing the
/// interface: every other method is the production one, so a test that reaches
/// past the override is still driving real behaviour, and a method added to
/// [ClarificationService] does not break this file (#454).
class _FailingClarificationService extends DaoClarificationService {
  _FailingClarificationService(super.db);

  @override
  Future<String> clarifyCaptureToOutcome(
    String captureId, {
    required RoutingKind to,
    required String userId,
    required String title,
    String? notes,
    DateTime? dueDate,
    ActionDraft? action,
    Set<String>? personTagIds,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) =>
      Future<String>.error(StateError('write failed'));
}

/// A [ClarificationService] whose Capture-clarify write parks on [gate], so a
/// test can observe the UI mid-write. Real service underneath — see
/// [_FailingClarificationService].
class _BlockingClarificationService extends DaoClarificationService {
  _BlockingClarificationService(super.db, this.gate);

  final Future<void> gate;

  @override
  Future<String> clarifyCaptureToOutcome(
    String captureId, {
    required RoutingKind to,
    required String userId,
    required String title,
    String? notes,
    DateTime? dueDate,
    ActionDraft? action,
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
      dueDate: dueDate,
      action: action,
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

  /// The live query itself failed. Distinct from [emitMissing]: local storage
  /// has not said the row is gone, it has not said anything.
  void emitError() => _controller.addError(Exception('watch failed'));

  Future<void> close() => _controller.close();
}

/// An Inbox that holds a live listener on the subject, so the autoDispose
/// [captureProvider] is already in `AsyncData` when the clarify screen mounts.
class _LiveSubjectInbox extends ConsumerWidget {
  const _LiveSubjectInbox({required this.captureId});

  final String captureId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(captureProvider(captureId));
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => context.push('/inbox/$captureId/clarify'),
          child: const Text('Clarify'),
        ),
      ),
    );
  }
}

Widget _buildApp(
  GtdDatabase db,
  String captureId, {
  ClarificationService? clarificationService,
  List<Tag>? personTags,
  _CaptureFeed? captureFeed,
  // Starts on the Inbox with a live listener already bound to the subject, so
  // the autoDispose provider is holding data by the time the clarify screen
  // mounts. Reproduces the real ordering: the screen is not always the thing
  // that brings the subject into existence.
  bool subjectAlreadyLive = false,
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
        initialLocation:
            subjectAlreadyLive ? '/inbox' : '/inbox/$captureId/clarify',
        routes: [
          GoRoute(
            path: '/inbox',
            builder: (context, _) => subjectAlreadyLive
                ? _LiveSubjectInbox(captureId: captureId)
                : const Scaffold(body: Text('Inbox')),
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

    testWidgets('pins the global capture action in the bar (#458)',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      // Direct find.byKey: the pinned slot never overflows.
      expect(find.byKey(const Key('capture_action')), findsOneWidget);
    });

    testWidgets(
        'Next Action carves a linked Outcome, stamps the Capture, and clears '
        'the Inbox', (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await _acceptNextActionDialog(tester);

      // Clarifying creates an Outcome rather than flipping a column, and the
      // link back to the Capture is the provenance record (ADR-0006).
      final outcome = await _outcomeOf(db, 'x');
      expect(outcome, isNotNull);
      expect(outcome!.clarified, isTrue);
      expect(outcome.title, 'Buy milk');
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNotNull);
      // And the clarified Capture leaves the Inbox.
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

    testWidgets('discarding an untitled Capture keeps its original title',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Half a thought'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('clarify_title')), '');
      await tester.pump();

      await _scrollAndTap(tester, 'Discard Capture');

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
        clarificationService: _BlockingClarificationService(db, gate.future),
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
      await tester.pumpAndSettle();

      // The guarded window opens with the *tap*, not with the write:
      // `_runOnce` latches before [NextActionDialog] is shown, so Skip is
      // already shut while the user is still typing the phrase.
      expect(_skipEnabled(tester), isFalse,
          reason: 'the dialog is inside the guarded window too');

      await tester.tap(find.text('Save'));
      await tester.pump();

      // Skip sits outside the action bar, so it does not inherit the bar's
      // in-flight disabling. Left live, it would pop the screen mid-write and
      // skip the post-route text flush.
      expect(_skipEnabled(tester), isFalse);

      gate.complete();
      await tester.pumpAndSettle();
      expect(await _outcomeOf(db, 'x'), isNotNull);
    });

    testWidgets(
        'the pinned capture action is suppressed while a write is in flight',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      final gate = Completer<void>();
      await tester.pumpWidget(_buildApp(
        db,
        'x',
        clarificationService: _BlockingClarificationService(db, gate.future),
      ));
      await tester.pumpAndSettle();

      // Present before routing starts — the capture action lives in the bar, so
      // it needs no scrolling.
      expect(find.byKey(const Key('capture_action')), findsOneWidget);

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pump();

      // Capture opens a modal from this route; leaving it live mid-write is the
      // same exposure the back arrow and Skip are gated against. Suppress it
      // alongside them so no Capture sheet can be opened over an
      // already-clarified subject during the guarded window.
      expect(find.byKey(const Key('capture_action')), findsNothing);

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
        clarificationService: _BlockingClarificationService(db, gate.future),
      ));
      await tester.pumpAndSettle();

      // Edit the title so the write in flight is carrying something: the
      // routing verdict reads the draft at tap time and mints the Outcome
      // from it.
      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'New title');
      await tester.pump();
      expect(_backEnabled(tester), isTrue);

      await tester.ensureVisible(find.text('Next Action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      // Save before driving platform back, or the pop would land on the
      // dialog — the topmost route — and say nothing about the screen's own
      // guard. Settle so the dialog is fully gone by the time it is driven.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.byType(NextActionDialog), findsNothing);

      // The app-bar button and platform back are separate escapes from Skip;
      // either one popping here leaves the routing verdict landing against a
      // screen the user has already left — the tap gives no feedback and a
      // failure has nowhere to report.
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

      // The edit lands on the Outcome — that is what clarification produces.
      expect((await _outcomeOf(db, 'x'))!.title, 'New title');
      // …and not on the Capture, which keeps the raw fragment (ADR-0023).
      expect((await db.captureDao.getCapture('x'))!.title, 'Buy milk');
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
      // a no-op: the Capture stays in the Inbox, and the dialog never opens.
      // This is why #689 adds no blank-title guard of its own — the arm #691
      // left stalling in `_nextWithDialog` is unreachable from this surface,
      // so a second runtime check would be dead code.
      expect(find.byType(NextActionDialog), findsNothing);
      expect(await _outcomeOf(db, 'x'), isNull);
      expect((await db.captureDao.getCapture('x'))!.clarifiedAt, isNull);
      expect(find.text('Title is required to process'), findsOneWidget);
    });

    testWidgets('clarifying an untouched Capture invents no attributes',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      // The real service, with nothing wrapped around it: what the screen sent
      // is exactly what the row now holds, so the row is the assertion.
      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await _acceptNextActionDialog(tester);

      // Nothing was entered, so nothing may be fabricated into the Outcome.
      final outcome = (await _outcomeOf(db, 'x'))!;
      expect(outcome.notes, isNull);
      expect(outcome.dueDate, isNull);
      expect(outcome.clarified, isTrue);
      // Effort read raw: the D2 projection COALESCEs the current Action's
      // values over the columns, so `outcome.energyLevel` would resolve on the
      // Action and pass whether or not the column was written.
      expect(await _rawEffortColumns(db, outcome.id), (energy: null, time: null));
      // …and the birth Action invented none either — the draft carried no
      // effort, so neither grain may have any.
      final action = await db.actionDao.getCurrentAction(outcome.id);
      expect(action?.energyLevel, isNull);
      expect(action?.timeEstimate, isNull);
    });

    testWidgets('effort set on the card travels as one ActionDraft — onto the '
        'Outcome columns and through them onto the birth Action',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(
        of: find.byType(ClarifyEnergyPicker),
        matching: find.text('High'),
      ));
      await tester.pump();
      await tester.tap(find.text('30m'));
      await tester.pump();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await _acceptNextActionDialog(tester);

      // That both grains carry the same pair is what says the card composed
      // one ActionDraft rather than three loose fields: the columns are
      // written from the draft and the birth Action is seeded from them, so
      // effort split across two paths would show up as a mismatch here.
      // ClarifyDraft.assemble's own unit tests pin the composition directly.
      //
      // The raw columns (D1/D3 draft store) — read raw, because a current
      // Action exists on this route and the projection's COALESCE would
      // resolve on *its* values no matter what the columns hold.
      final outcome = (await _outcomeOf(db, 'x'))!;
      expect(await _rawEffortColumns(db, outcome.id), (energy: 'high', time: 30));
      // … and the birth Action seeded from them, which only holds because
      // insertOutcome still runs before applyRouting.
      final action = await db.actionDao.getCurrentAction(outcome.id);
      expect(action?.actionText, 'Buy milk');
      expect(action?.energyLevel, 'high');
      expect(action?.timeEstimate, 30);
    });

    testWidgets('a failed write surfaces an error and does not pop',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(
        _buildApp(
          db,
          'x',
          clarificationService: _FailingClarificationService(db),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await _acceptNextActionDialog(tester);

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
      await db.into(db.todos).insert(_companion(id: 'x', title: 'Buy milk'));
      final service = DaoClarificationService(db);

      await service.updateFields('x');

      final row =
          await (db.select(db.todos)..where((t) => t.id.equals('x')))
              .getSingle();
      expect(row.lastClarifiedAt, isNull);
    });

    test('clearNotes nulls the column and stamps', () async {
      await db.into(db.todos).insert(
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
      await _acceptNextActionDialog(tester);

      // The save on the way out must carry the row's current title, not the
      // one this screen happened to load with.
      expect((await db.captureDao.getCapture('x'))!.title, 'Buy oat milk');
      expect((await _outcomeOf(db, 'x'))!.title, 'Buy oat milk');
    });

    testWidgets('notes cleared after an incoming edit reach the Outcome as null',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      // Notes reach the row while the screen is open. Before #427 the screen
      // held a load-time snapshot that still said "no notes", so it never put
      // them in the field and the clear below would have been a no-op on an
      // already-empty box rather than a real clear.
      await db.captureDao.updateFields('x', notes: 'Full fat');
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('clarify_notes')))
            .controller
            ?.text,
        'Full fat',
        reason: 'the incoming notes must reach the clean field, or clearing '
            'it below is not a clear',
      );

      await tester.enterText(find.byKey(const Key('clarify_notes')), '');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next Action'));
      await tester.pumpAndSettle();
      await _acceptNextActionDialog(tester);

      // The user's clear is an interpretation, so it lands on the Outcome…
      expect((await _outcomeOf(db, 'x'))!.notes, isNull);
      // …while the Capture keeps the fragment as it was (ADR-0023).
      expect((await db.captureDao.getCapture('x'))!.notes, 'Full fat');
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
      await (db.delete(db.captures)..where((c) => c.id.equals('x'))).go();
      feed.emitMissing();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('clarify_title')), findsNothing);
      expect(find.text('Next Action'), findsNothing);
      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
    });

    testWidgets('the missing state offers a way back to the Inbox',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      await feed.emitFrom(db, 'x');
      await tester.pumpAndSettle();

      await (db.delete(db.captures)..where((c) => c.id.equals('x'))).go();
      feed.emitMissing();
      await tester.pumpAndSettle();

      // Without a way out the user is stranded on a subject that no longer
      // exists — platform back is not an affordance the screen offers.
      await tester.tap(find.text('Back to Inbox'));
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byKey(const Key('clarify_subject_missing')), findsNothing);
    });

    testWidgets('a failed subject query renders an error, not a spinner',
        (tester) async {
      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x', captureFeed: feed));
      feed.emitError();
      await tester.pumpAndSettle();

      expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // An error is not an absence: the row may well still be there.
      expect(find.byKey(const Key('clarify_subject_missing')), findsNothing);
    });

    testWidgets(
        'the energy picker chips stay inside the screen at 320dp (#477 '
        'pre-existing overflow)', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await db.captureDao
          .insertCapture(_captureCompanion(id: 'x', title: 'Buy milk'));

      await tester.pumpWidget(_buildApp(db, 'x'));
      await tester.pumpAndSettle();

      final picker = tester.getRect(find.byType(ClarifyEnergyPicker));
      // Measured rather than inferred from `takeException()` — see
      // task_detail_screen_test.dart's note on why that is unreliable here.
      for (final label in ['Low', 'Medium', 'High']) {
        final chip = tester.getRect(find.ancestor(
          of: find.text(label),
          matching: find.byType(AnimatedContainer),
        ));
        expect(chip.left, greaterThanOrEqualTo(picker.left),
            reason: '$label chip starts inside the picker');
        expect(chip.right, lessThanOrEqualTo(picker.right),
            reason:
                '$label chip must not overflow the picker at 320dp width');
        expect(chip.width, greaterThan(0.0),
            reason: '$label chip is not squeezed to nothing');
      }
    });
  });
}
