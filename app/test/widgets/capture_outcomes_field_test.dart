/// Widget tests for [CaptureOutcomesField] — the n-m clarify surface (#434).
///
/// The field's contract is entirely about *which* write a gesture performs, so
/// every test drives the real widget against a real Drift database and asserts
/// on the resulting rows. The only overrides are the provider streams the card
/// binds to, fed from real DB reads through controllers the test owns: awaiting
/// a live drift `watch()` inside `testWidgets` never completes, because the
/// test binding owns the clock (docs/TESTING.md).
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
import 'package:jeeves/providers/clarify_mode_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/widgets/capture_outcomes_field.dart';
import 'package:jeeves/widgets/clarify_card.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<void> _insertCapture(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: const Value('Raw fragment'),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
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

  /// Mounts the field for [captureId] and seeds its link list from the DB.
  Future<void> pumpField(
    WidgetTester tester,
    String captureId, {
    VoidCallback? onCompleted,
    Set<String> tagIds = const {},
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        carvedOutcomesProvider(captureId).overrideWith((_) => carved.stream),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CaptureOutcomesField(
              captureId: captureId,
              tagIds: tagIds,
              onCompleted: () async => onCompleted?.call(),
            ),
          ),
        ),
      ),
    ));
    carved.add(await _readCarved(db, captureId));
    await _pumpFrames(tester);
  }

  /// Re-reads the links and pushes them down the controller, standing in for
  /// the live drift stream the production provider subscribes to.
  Future<void> refresh(WidgetTester tester, String captureId) async {
    carved.add(await _readCarved(db, captureId));
    await _pumpFrames(tester);
  }

  group('one field, both gestures', () {
    testWidgets('the create row carves a new Outcome and links it',
        (tester) async {
      await _insertCapture(db, 'c1');
      await pumpField(tester, 'c1');

      await tester.enterText(
          find.byKey(const Key('capture_outcome_field')), 'Book the flights');
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_outcome_create')));
      await _pumpFrames(tester);

      final linked = await db.captureDao.outcomeIdsForCapture('c1');
      expect(linked, hasLength(1));
      expect((await db.todoDao.getTodo(linked.single))!.title,
          'Book the flights');
      // The clarify act is not over — the Capture is still in the Inbox.
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    });

    testWidgets('picking a match merges into the existing Outcome',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await pumpField(tester, 'c1');

      await tester.enterText(
          find.byKey(const Key('capture_outcome_field')), 'Plan');
      await _pumpFrames(tester);
      expect(find.byKey(const Key('capture_outcome_match_o1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('capture_outcome_match_o1')));
      await _pumpFrames(tester);

      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      // Merge links, never consumes: the Outcome is untouched and the Capture
      // survives.
      expect((await db.todoDao.getTodo('o1'))!.title, 'Plan the trip');
      expect(await db.captureDao.getCapture('c1'), isNotNull);
    });

    testWidgets('the create row is offered even when a match exists',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await pumpField(tester, 'c1');

      await tester.enterText(
          find.byKey(const Key('capture_outcome_field')), 'Plan');
      await _pumpFrames(tester);

      // One field, never a dead end: the user can always split instead of
      // merging into whatever happened to match.
      expect(find.byKey(const Key('capture_outcome_create')), findsOneWidget);
      expect(find.byKey(const Key('capture_outcome_match_o1')), findsOneWidget);
    });

    testWidgets('an already-linked Outcome is not offered as a match',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpField(tester, 'c1');

      await tester.enterText(
          find.byKey(const Key('capture_outcome_field')), 'Plan');
      await _pumpFrames(tester);

      expect(find.byKey(const Key('capture_outcome_match_o1')), findsNothing);
    });

    testWidgets('several carves accumulate — one Capture, several Outcomes',
        (tester) async {
      await _insertCapture(db, 'c1');
      await pumpField(tester, 'c1');

      for (final title in ['First step', 'Second step']) {
        await tester.enterText(
            find.byKey(const Key('capture_outcome_field')), title);
        await _pumpFrames(tester);
        await tester.tap(find.byKey(const Key('capture_outcome_create')));
        await refresh(tester, 'c1');
      }

      expect(await db.captureDao.outcomeIdsForCapture('c1'), hasLength(2));
      expect(find.text('First step'), findsOneWidget);
      expect(find.text('Second step'), findsOneWidget);
    });
  });

  group('verdict footer', () {
    testWidgets('reads Discard Capture at zero Outcomes and stamps',
        (tester) async {
      await _insertCapture(db, 'c1');
      var completed = false;
      await pumpField(tester, 'c1', onCompleted: () => completed = true);

      expect(find.text('Discard Capture'), findsOneWidget);
      expect(find.text('Done with this Capture'), findsNothing);

      await tester.tap(find.byKey(const Key('capture_verdict')));
      await _pumpFrames(tester);

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect(completed, isTrue);
    });

    testWidgets('swaps to Done with this Capture once an Outcome is linked',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpField(tester, 'c1');

      expect(find.text('Done with this Capture'), findsOneWidget);
      expect(find.text('Discard Capture'), findsNothing);
    });

    testWidgets('Done stamps clarified_at and keeps every linked Outcome',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Plan the trip', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      var completed = false;
      await pumpField(tester, 'c1', onCompleted: () => completed = true);

      await tester.tap(find.byKey(const Key('capture_verdict')));
      await _pumpFrames(tester);

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.todoDao.getTodo('o1'), isNotNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), ['o1']);
      expect(completed, isTrue);
    });
  });

  group('unlink semantics differ by provenance', () {
    testWidgets('unlinking a session-carved Outcome deletes it',
        (tester) async {
      await _insertCapture(db, 'c1');
      await pumpField(tester, 'c1');

      await tester.enterText(
          find.byKey(const Key('capture_outcome_field')), 'Carved here');
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_outcome_create')));
      await refresh(tester, 'c1');

      final outcomeId =
          (await db.captureDao.outcomeIdsForCapture('c1')).single;
      await tester.tap(find.descendant(
        of: find.byKey(Key('linked_outcome_$outcomeId')),
        matching: find.byIcon(Icons.close),
      ));
      await refresh(tester, 'c1');

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // Undoing the carve leaves nothing behind.
      expect(await db.todoDao.getTodo(outcomeId), isNull);
    });

    testWidgets('unlinking a pre-existing Outcome only detaches it',
        (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Existing work', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await pumpField(tester, 'c1');

      await tester.tap(find.descendant(
        of: find.byKey(const Key('linked_outcome_o1')),
        matching: find.byIcon(Icons.close),
      ));
      await refresh(tester, 'c1');

      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // The user's existing work survives the unmerge.
      expect(await db.todoDao.getTodo('o1'), isNotNull);
    });
  });

  group('provenance', () {
    testWidgets('a merged Outcome carries a from-N-Captures chip',
        (tester) async {
      await _insertCapture(db, 'c1');
      await _insertCapture(db, 'c2');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Shared outcome', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);
      await db.captureDao.linkOutcome('c2', 'o1', _userId);

      await pumpField(tester, 'c1');

      expect(find.text('from 2 Captures'), findsOneWidget);
    });

    testWidgets('a solo Outcome carries no provenance chip', (tester) async {
      await _insertCapture(db, 'c1');
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Solo outcome', userId: _userId);
      await db.captureDao.linkOutcome('c1', 'o1', _userId);

      await pumpField(tester, 'c1');

      expect(find.textContaining('from '), findsNothing);
    });
  });

  group('mode gating on ClarifyCard', () {
    /// Pins the 1-1 contract: the shipped clarify surface must not grow the
    /// n-m field, and the n-m surface must not keep the routing bar.
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
            contextTagsProvider
                .overrideWith((_) => Stream.value(const <Tag>[])),
            projectTagsProvider
                .overrideWith((_) => Stream.value(const <Tag>[])),
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

    testWidgets('oneToOne keeps PROCESS TO and grows no n-m field',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await _insertCapture(db, 'c1');
      final capture = (await db.captureDao.getCapture('c1'))!;

      await tester.pumpWidget(cardHarness(ClarifyMode.oneToOne, capture));
      carved.add(const []);
      await _pumpFrames(tester);

      expect(find.text('PROCESS TO'), findsOneWidget);
      expect(find.byType(CaptureOutcomesField), findsNothing);
      expect(find.byKey(const Key('capture_verdict')), findsNothing);
    });

    testWidgets('nToM renders the unified field instead of PROCESS TO',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await _insertCapture(db, 'c1');
      final capture = (await db.captureDao.getCapture('c1'))!;

      await tester.pumpWidget(cardHarness(ClarifyMode.nToM, capture));
      carved.add(const []);
      await _pumpFrames(tester);

      expect(find.text('PROCESS TO'), findsNothing);
      expect(find.byKey(const Key('capture_outcome_field')), findsOneWidget);
      expect(find.byKey(const Key('capture_verdict')), findsOneWidget);
    });
  });
}
