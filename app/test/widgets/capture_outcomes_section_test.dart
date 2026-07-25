/// Widget tests for [CaptureOutcomesSection] — the n-m clarify surface (#434).
///
/// The surface's contract is entirely about *which* write a gesture performs,
/// so every test drives the real widget against a real Drift database and
/// asserts on the resulting rows. The only overrides are the provider streams
/// the surface binds to, fed from real DB reads through controllers the test
/// owns: awaiting a live drift `watch()` inside `testWidgets` never completes,
/// because the test binding owns the clock (docs/TESTING.md).
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/capture_dao.dart' show CarvedOutcome;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/providers/clarify_mode_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/widgets/capture_outcomes_section.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/state_surfaces.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Capture> _insertCapture(
  GtdDatabase db,
  String id, {
  String title = 'Raw fragment',
  String? notes,
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    notes: notes != null ? Value(notes) : const Value.absent(),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return (await db.captureDao.getCapture(id))!;
}

/// One-shot read of the same rows [carvedOutcomesProvider] streams, so the
/// test can push a fresh snapshot down its own controller after each write.
Future<List<CarvedOutcome>> _readCarved(GtdDatabase db, String captureId) =>
    db.captureDao.watchCarvedOutcomes(captureId).first;

/// Pumps a bounded number of frames. The n-m surface writes through the real
/// database, and every `notifyCapturesViewWrite` keeps drift's query store
/// emitting, so `pumpAndSettle` never reaches a quiet frame.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Pins [clarifyModeProvider] to a fixed mode, so the gating tests do not
/// depend on the synced-preferences store loading.
class _FixedClarifyMode extends ClarifyModeNotifier {
  _FixedClarifyMode(this.mode);
  final ClarifyMode mode;
  @override
  ClarifyMode build() => mode;
}

/// The real service with retraction made to fail, so the surface's own error
/// path is observable. A subclass rather than a fake: every other write on it
/// is still the production one.
class _FailingRetractService extends DaoClarificationService {
  _FailingRetractService(super.db);

  @override
  Future<void> unlinkOutcome(
    String captureId,
    String outcomeId, {
    required bool deleteCarved,
  }) async =>
      throw StateError('write failed');
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late StreamController<List<CarvedOutcome>> carved;

  setUp(() async {
    db = _openInMemory();
    carved = StreamController<List<CarvedOutcome>>.broadcast();
  });

  tearDown(() async {
    await carved.close();
    await db.close();
  });

  /// Mounts the surface for [capture] and seeds its link list from the DB.
  Future<void> pumpSection(
    WidgetTester tester,
    Capture capture, {
    VoidCallback? onCompleted,
    Set<String> tagIds = const {},
    ClarificationService? service,
    // Leaves the link stream silent, so the surface stays on the loading
    // state and the test can drive it to error or to a first value itself.
    bool seedLinks = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        carvedOutcomesProvider(capture.id).overrideWith((_) => carved.stream),
        if (service != null)
          clarificationServiceProvider.overrideWithValue(service),
        personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CaptureOutcomesSection(
              capture: capture,
              tagIds: tagIds,
              onCompleted: () async => onCompleted?.call(),
            ),
          ),
        ),
      ),
    ));
    if (seedLinks) carved.add(await _readCarved(db, capture.id));
    await _pumpFrames(tester);
  }

  /// Re-reads the links and pushes them down the controller, standing in for
  /// the live drift stream the production provider subscribes to.
  Future<void> refresh(WidgetTester tester, String captureId) async {
    carved.add(await _readCarved(db, captureId));
    await _pumpFrames(tester);
  }

  /// Names an Outcome in the form and routes it to Next Action — the gesture
  /// that commits a carve.
  Future<void> nameAndRoute(WidgetTester tester, String title) async {
    await tester.enterText(find.byKey(const Key('outcome_title')), title);
    await _pumpFrames(tester);
    await tester.tap(find.text('Next Action'));
    await _pumpFrames(tester);
  }

  group('the Capture is a record, not a field', () {
    testWidgets('renders the Capture text read-only with its metadata',
        (tester) async {
      final capture = await _insertCapture(db, 'c1',
          title: 'Sort out the trip', notes: 'before the deadline');
      await pumpSection(tester, capture);

      expect(find.byKey(const Key('capture_text')), findsOneWidget);
      expect(find.text('Sort out the trip'), findsOneWidget);
      expect(find.text('before the deadline'), findsOneWidget);
      expect(find.textContaining('Captured '), findsOneWidget);
      // The Capture's own text is provenance here — the record of what was
      // thought. Only the Outcome below it is editable.
      expect(find.widgetWithText(TextField, 'Sort out the trip'), findsNothing);
    });
  });

  group('the list, the call to add, and the form', () {
    testWidgets('an empty list renders nothing at all and opens the form',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      // No header and no empty state: there is nothing to say about an empty
      // list that the open form does not already say by being open. This is
      // also what makes 1-1 mode look unchanged.
      expect(find.text('OUTCOMES'), findsNothing);
      expect(find.text('No Outcomes yet'), findsNothing);
      expect(find.byKey(const Key('add_outcome_call')), findsNothing);
      // The first Outcome must not cost an extra tap.
      expect(find.byKey(const Key('outcome_title')), findsOneWidget);
    });

    testWidgets('routing the form collapses it into a row and offers the next',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await nameAndRoute(tester, 'Book the flights');
      await refresh(tester, 'c1');

      // The carve landed as a row…
      expect(find.text('OUTCOMES'), findsOneWidget);
      expect(find.text('Book the flights'), findsWidgets);
      // …the form collapsed…
      expect(find.byKey(const Key('outcome_title')), findsNothing);
      // …and the call to add another took its place.
      expect(find.byKey(const Key('add_outcome_call')), findsOneWidget);
    });

    testWidgets('the call to add swaps itself for the form in place',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);
      await nameAndRoute(tester, 'Book the flights');
      await refresh(tester, 'c1');

      await tester.tap(find.byKey(const Key('add_outcome_call')));
      await _pumpFrames(tester);

      expect(find.byKey(const Key('outcome_title')), findsOneWidget);
      expect(find.byKey(const Key('add_outcome_call')), findsNothing);
    });

    testWidgets('several carves accumulate — one Capture, several Outcomes',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await nameAndRoute(tester, 'First step');
      await refresh(tester, 'c1');
      await tester.tap(find.byKey(const Key('add_outcome_call')));
      await _pumpFrames(tester);
      await nameAndRoute(tester, 'Second step');
      await refresh(tester, 'c1');

      expect(await db.captureDao.outcomeIdsForCapture('c1'), hasLength(2));
      expect(find.text('First step'), findsWidgets);
      expect(find.text('Second step'), findsWidgets);
      // The Capture is still in the Inbox: only the verdict ends the act.
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    });

    testWidgets('a row shows the Outcome, its next action and its Context',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.tagDao.upsertTag(TagsCompanion(
        id: const Value('t1'),
        name: const Value('@home'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Tidy the shed', userId: _userId);
      await db.todoDao.applyRouting(
        'o1',
        to: RoutingKind.nextAction,
        nextActionText: 'Clear the bench',
      );
      await db.tagDao.assignTag('o1', 't1', _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);

      await pumpSection(tester, capture);

      expect(find.text('Tidy the shed'), findsOneWidget);
      expect(find.text('Clear the bench'), findsOneWidget);
      expect(find.text('@home'), findsOneWidget);
    });

    testWidgets('the row reads the current Action, not the cursor column',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Tidy the shed', userId: _userId);
      await db.todoDao.applyRouting(
        'o1',
        to: RoutingKind.nextAction,
        nextActionText: 'Clear the bench',
      );
      // Skew the retired cursor column directly (ADR-0022 — it is neither
      // read nor written by the app): the Action row is untouched and stays
      // the evidence the row renders (ADR-0001 story 3).
      await (db.update(db.todos)..where((t) => t.id.equals('o1'))).write(
        const TodosCompanion(nextActionText: Value('stale cursor phrase')),
      );
      await db.captureDao.linkOutcome('c1', 'o1', _userId);

      await pumpSection(tester, capture);

      expect(find.text('Clear the bench'), findsOneWidget);
      expect(find.text('stale cursor phrase'), findsNothing);
    });
  });

  group('one field, two verbs', () {
    testWidgets('the typed title carves a new Outcome when routed',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await nameAndRoute(tester, 'Book the flights');

      final linked = await db.captureDao.outcomeIdsForCapture('c1');
      expect(linked, hasLength(1));
      expect(
        (await db.todoDao.getTodo(linked.single))!.title,
        'Book the flights',
      );
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    });

    testWidgets('picking a match merges into the existing Outcome',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await pumpSection(tester, capture);

      await tester.enterText(find.byKey(const Key('outcome_title')), 'Plan');
      await _pumpFrames(tester);
      expect(find.byKey(const Key('outcome_match_o1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('outcome_match_o1')));
      await _pumpFrames(tester);

      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      // Merge links, never consumes: the Outcome is untouched and the Capture
      // survives.
      expect((await db.todoDao.getTodo('o1'))!.title, 'Plan the trip');
      expect(await db.captureDao.getCapture('c1'), isNotNull);
    });

    testWidgets('the create row is offered alongside a match', (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await pumpSection(tester, capture);

      await tester.enterText(find.byKey(const Key('outcome_title')), 'Plan');
      await _pumpFrames(tester);

      // One field, never a dead end: the user can always split instead of
      // merging into whatever happened to match.
      expect(find.byKey(const Key('outcome_create')), findsOneWidget);
      expect(find.byKey(const Key('outcome_match_o1')), findsOneWidget);
    });

    testWidgets('an already-linked Outcome is not offered as a match',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture);

      await tester.tap(find.byKey(const Key('add_outcome_call')));
      await _pumpFrames(tester);
      await tester.enterText(find.byKey(const Key('outcome_title')), 'Plan');
      await _pumpFrames(tester);

      expect(find.byKey(const Key('outcome_match_o1')), findsNothing);
    });
  });

  group('the form carries the whole clarify draft', () {
    testWidgets('notes, energy and time estimate land on the carve',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await tester.enterText(
          find.byKey(const Key('outcome_title')), 'Book the flights');
      await _pumpFrames(tester);
      await tester.enterText(
          find.byKey(const Key('outcome_notes')), 'Morning departure');
      await _pumpFrames(tester);
      await tester.tap(find.text('High'));
      await _pumpFrames(tester);
      await tester.tap(find.text('45m'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Next Action'));
      await _pumpFrames(tester);

      // The pickers are on screen in this mode, so what they collect must
      // reach the Outcome — rendering a field whose value is silently dropped
      // is the bug this pins.
      final id = (await db.captureDao.outcomeIdsForCapture('c1')).single;
      final outcome = (await db.todoDao.getTodo(id))!;
      expect(outcome.notes, 'Morning departure');
      expect(outcome.energyLevel, 'high');
      expect(outcome.timeEstimate, 45);
      expect(outcome.intent, 'next');
    });

    testWidgets('the routing destination lands on the carve', (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await tester.enterText(
          find.byKey(const Key('outcome_title')), 'Learn guitar');
      await _pumpFrames(tester);
      await tester.tap(find.text('Someday'));
      await _pumpFrames(tester);

      final id = (await db.captureDao.outcomeIdsForCapture('c1')).single;
      expect((await db.todoDao.getTodo(id))!.intent, 'maybe');
    });

    testWidgets('an unnamed Outcome cannot be routed', (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await tester.tap(find.text('Next Action'));
      await _pumpFrames(tester);

      // An Outcome must be nameable; a blank form creates nothing.
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
    });
  });

  group('routing narrows to three destinations', () {
    testWidgets('Done and Trash are withheld while the form is open',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Existing', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture);
      await tester.tap(find.byKey(const Key('add_outcome_call')));
      await _pumpFrames(tester);

      expect(find.text('Next Action'), findsOneWidget);
      expect(find.text('Waiting For'), findsOneWidget);
      expect(find.text('Someday'), findsOneWidget);
      // Done is a completion event, not a destination you route to while
      // clarifying; trashing an Outcome belongs on its own surface.
      expect(find.text('Done'), findsNothing);
      expect(find.text('Trash'), findsNothing);
    });

    testWidgets('with the form collapsed only the verdict remains',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Existing', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture);

      expect(find.text('Next Action'), findsNothing);
      expect(find.text('Waiting For'), findsNothing);
      expect(find.text('Someday'), findsNothing);
      expect(find.text('Done with this Capture'), findsOneWidget);
    });
  });

  group('the verdict', () {
    testWidgets('reads Discard Capture at zero Outcomes and stamps',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      var completed = false;
      await pumpSection(tester, capture, onCompleted: () => completed = true);

      expect(find.text('Discard Capture'), findsOneWidget);
      expect(find.text('Done with this Capture'), findsNothing);

      await tester.tap(find.text('Discard Capture'));
      await _pumpFrames(tester);

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect(await db.select(db.todos).get(), isEmpty);
      expect(completed, isTrue);
    });

    testWidgets('stays Discard Capture while the form is merely filled in',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await tester.enterText(
          find.byKey(const Key('outcome_title')), 'Half a thought');
      await _pumpFrames(tester);

      // A half-written Outcome is not a linked one. The verdict tracks the
      // list, not the form.
      expect(find.text('Discard Capture'), findsOneWidget);
      expect(find.text('Done with this Capture'), findsNothing);
    });

    testWidgets('swaps to Done with this Capture once an Outcome is linked',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture);

      expect(find.text('Done with this Capture'), findsOneWidget);
      expect(find.text('Discard Capture'), findsNothing);
    });

    testWidgets('Done stamps clarified_at and keeps every linked Outcome',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      var completed = false;
      await pumpSection(tester, capture, onCompleted: () => completed = true);

      await tester.tap(find.text('Done with this Capture'));
      await _pumpFrames(tester);

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.todoDao.getTodo('o1'), isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      expect(completed, isTrue);
    });
  });

  // Discard drops this session's carves. Offering it against a list nobody
  // has successfully read would destroy Outcomes on the strength of a failed
  // query, so the destructive verdict is gated on the list being *known* —
  // loading and error are not "no Outcomes" (widgets/state_surfaces.dart).
  group('the verdict never rests on an unknown list', () {
    testWidgets('withholds Discard while the links are still loading',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture, seedLinks: false);

      expect(find.text('Discard Capture'), findsNothing);

      // The slot still holds the non-destructive verdict so the bar does not
      // jump when the answer lands, but it is not tappable while in flight.
      final btn = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Done with this Capture'),
        matching: find.byType(OutlinedButton),
      ));
      expect(btn.onPressed, isNull);
    });

    testWidgets('withholds Discard when the links fail, and Done still works',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      var completed = false;
      await pumpSection(tester, capture,
          seedLinks: false, onCompleted: () => completed = true);
      carved.addError(StateError('links unavailable'));
      await _pumpFrames(tester);

      expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
      expect(find.text('Discard Capture'), findsNothing);

      // Done is the way out of the dead end, and it destroys nothing: the
      // Outcome the failed read never showed is still linked afterwards.
      await tester.tap(find.text('Done with this Capture'));
      await _pumpFrames(tester);

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.todoDao.getTodo('o1'), isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      expect(completed, isTrue);
    });

    testWidgets('an error after a loaded-empty list still withholds Discard',
        (tester) async {
      // Error before absence: Riverpod retains the previous value alongside
      // the error, so an absence-first check would read this as a confirmed
      // "no Outcomes" and offer to discard on the strength of a stale answer.
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);
      expect(find.text('Discard Capture'), findsOneWidget);

      carved.addError(StateError('links went away'));
      await _pumpFrames(tester);

      expect(find.text('Discard Capture'), findsNothing);
      expect(find.text('Done with this Capture'), findsOneWidget);
    });
  });

  group('retraction cuts by provenance', () {
    testWidgets('retracting a session-carved Outcome deletes it',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpSection(tester, capture);

      await nameAndRoute(tester, 'Carved here');
      await refresh(tester, 'c1');

      final outcomeId = (await db.captureDao.outcomeIdsForCapture('c1')).single;
      await tester.tap(find.descendant(
        of: find.byKey(Key('linked_outcome_$outcomeId')),
        matching: find.byIcon(Icons.close),
      ));
      await refresh(tester, 'c1');

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // Undoing the carve leaves nothing behind.
      expect(await db.todoDao.getTodo(outcomeId), isNull);
    });

    testWidgets('retracting a pre-existing Outcome only detaches it',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Existing work', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture);

      await tester.tap(find.descendant(
        of: find.byKey(const Key('linked_outcome_o1')),
        matching: find.byIcon(Icons.close),
      ));
      await refresh(tester, 'c1');

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // The user's existing work survives the unmerge.
      expect(await db.todoDao.getTodo('o1'), isNotNull);
    });

    testWidgets('a failed retraction is reported and the surface stays usable',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Existing work', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpSection(tester, capture,
          service: _FailingRetractService(db));

      await tester.tap(find.descendant(
        of: find.byKey(const Key('linked_outcome_o1')),
        matching: find.byIcon(Icons.close),
      ));
      await _pumpFrames(tester);

      // This surface owns the tap, so nothing above it can report the failure.
      // Swallowing it would leave the ✕ looking like it simply did nothing.
      expect(find.byKey(const Key('capture_outcomes_error')), findsOneWidget);
      // And the surface must not latch shut behind the throw.
      expect(find.text('Done with this Capture'), findsOneWidget);
    });
  });

  group('provenance', () {
    testWidgets('a merged Outcome carries a from-N-Captures chip',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await _insertCapture(db, 'c2');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Shared outcome', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await db.captureDao.linkOutcome('c2', 'o1', _userId);

      await pumpSection(tester, capture);

      expect(find.text('from 2 Captures'), findsOneWidget);
    });

    testWidgets('a solo Outcome carries no provenance chip', (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Solo outcome', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);

      await pumpSection(tester, capture);

      expect(find.textContaining('from '), findsNothing);
    });
  });

  group('mode gating on ClarifyCard', () {
    /// Pins the 1-1 contract: the shipped clarify surface must not grow the
    /// n-m section, and the n-m surface must not keep PROCESS TO or the
    /// Capture's own editable fields.
    Widget cardHarness(ClarifyMode mode, Capture capture) => ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            clarifyModeProvider.overrideWith(() => _FixedClarifyMode(mode)),
            captureProvider(capture.id)
                .overrideWith((_) => Stream.value(capture)),
            captureTagHintsProvider(capture.id)
                .overrideWith((_) => Stream.value(const <Tag>[])),
            carvedOutcomesProvider(capture.id)
                .overrideWith((_) => carved.stream),
            personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
            contextTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
            projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ClarifyCard.forCapture(captureId: capture.id),
            ),
          ),
        );

    // The card is a tall ListView, which does not build children far below
    // the viewport — each test below gives the window enough height that the
    // whole card is laid out and the assertions can see the bottom section.
    Future<void> pumpCard(
      WidgetTester tester,
      ClarifyMode mode,
      Capture capture,
    ) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(cardHarness(mode, capture));
      // The card resolves the Capture before it builds the section, so the
      // section subscribes a frame later than the widget tree appears.
      // `carved` is a broadcast controller and replays nothing, so seeding it
      // any earlier drops the list on the floor and leaves the section stuck
      // loading — which is now visible, because loading no longer passes
      // itself off as an empty list.
      await _pumpFrames(tester);
      carved.add(const []);
      await _pumpFrames(tester);
    }

    testWidgets('oneToOne keeps PROCESS TO and grows no n-m section',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpCard(tester, ClarifyMode.oneToOne, capture);

      expect(find.text('PROCESS TO'), findsOneWidget);
      expect(find.byType(CaptureOutcomesSection), findsNothing);
    });

    testWidgets('oneToOne narrows to three destinations plus the verdict',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpCard(tester, ClarifyMode.oneToOne, capture);

      // 1-1 is this surface with two parameters flipped, so it loses Done for
      // the same reason and gains the Capture-scoped verdict in the slot Done
      // and Trash vacated.
      expect(find.text('Next Action'), findsOneWidget);
      expect(find.text('Waiting For'), findsOneWidget);
      expect(find.text('Someday'), findsOneWidget);
      expect(find.text('Done'), findsNothing);
      expect(find.text('Trash'), findsNothing);
      expect(find.text('Discard Capture'), findsOneWidget);
    });

    testWidgets('nToM renders the section instead of PROCESS TO',
        (tester) async {
      final capture = await _insertCapture(db, 'c1');
      await pumpCard(tester, ClarifyMode.nToM, capture);

      expect(find.text('PROCESS TO'), findsNothing);
      expect(find.byKey(const Key('capture_text')), findsOneWidget);
      expect(find.byKey(const Key('outcome_title')), findsOneWidget);
      expect(find.text('Discard Capture'), findsOneWidget);
    });
  });
}
