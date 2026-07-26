/// The clarify surfaces' divergence table, made executable.
///
/// Three surfaces render [ClarifyCard]: the ceremony Clarify Inbox step, the
/// standalone `/inbox/:id/clarify` screen and the Re-clarify route. What they
/// legitimately differ in is expressed as one option ([ClarifyTagSection]) and
/// three composition slots (`footer`, `missingCta`, `onProcessingChanged`).
/// Everything else is shared, and the tests here are what stops a future
/// change quietly forking it again.
///
/// Chrome is not on that list, deliberately: the body renders no `Scaffold`,
/// no `AppBar` and no `PopScope`, and never pops. That is asserted below too —
/// it is the property that lets one widget serve three hosts.
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
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/clarify_shared_widgets.dart';
import 'package:jeeves/widgets/context_tag_picker.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';
import 'package:jeeves/widgets/project_picker.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Capture> _insertCapture(
  GtdDatabase db, {
  required String id,
  String title = 'Buy milk',
}) async {
  final now = DateTime.now();
  await db.captureDao.insertCapture(CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
  return (await db.captureDao.getCapture(id))!;
}

Future<Tag> _insertTag(
  GtdDatabase db, {
  required String id,
  required String name,
  required String type,
}) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(id),
    name: Value(name),
    type: Value(type),
    userId: const Value(_userId),
  ));
  return (db.select(db.tags)..where((t) => t.id.equals(id))).getSingle();
}

Future<Set<String>> _joinedTagIds(GtdDatabase db, String todoId) async {
  final rows = await (db.select(db.todoTags)
        ..where((t) => t.todoId.equals(todoId)))
      .get();
  return {for (final r in rows) r.tagId};
}

/// The Capture path writes through the real database and each view-write
/// notification keeps drift's StreamQueryStore emitting, so `pumpAndSettle`
/// never reaches a quiet frame. Bounded pumping instead (docs/TESTING.md).
Future<void> _pumpFrames(WidgetTester tester, {int frames = 40}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _scrollAndTap(WidgetTester tester, String label) async {
  for (var i = 0; i < 15 && find.text(label).evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.text(label), findsOneWidget,
      reason: 'the $label button never came into view');
  await tester.ensureVisible(find.text(label));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(label));
}

/// A [ClarificationService] whose Capture-clarify write parks on [gate], so a
/// test can observe the surface mid-write.
class _BlockingClarificationService implements ClarificationService {
  _BlockingClarificationService(this.inner, this.gate);

  final ClarificationService inner;
  final Future<void> gate;

  @override
  Future<bool> captureExists(String captureId) => inner.captureExists(captureId);

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
    return inner.clarifyCaptureToOutcome(
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

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not used by this test');
}

/// A Capture card in whichever configuration a test is exercising.
///
/// The harness deliberately does **not** override `captureTagHintsProvider`.
/// That absence is the canary for [ClarifyTagSection.draftInputOnly]: if the
/// card ever watches the hint provider under that option, this file starts
/// subscribing to a real drift `watch()` and hangs.
Widget _card(
  GtdDatabase db,
  Capture capture, {
  required ClarifyTagSection tagSection,
  Widget? footer,
  Widget? missingCta,
  ValueChanged<bool>? onProcessingChanged,
  Future<void> Function(ProcessAction)? onAfterRoute,
  List<Tag> contextTags = const <Tag>[],
  Stream<Capture?>? captureStream,
  Stream<List<Tag>>? tagHintsStream,
  ClarificationService? clarificationService,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      captureProvider(capture.id).overrideWith(
        (_) => captureStream ?? Stream.value(capture),
      ),
      if (tagHintsStream != null)
        captureTagHintsProvider(capture.id).overrideWith(
          (_) => tagHintsStream,
        ),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(contextTags)),
      projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
    ],
    child: MaterialApp(
      // A host Scaffold, so the "renders no chrome" assertions below are about
      // the card rather than about there being no Scaffold anywhere.
      home: Scaffold(
        body: ClarifyCard.forCapture(
          captureId: capture.id,
          tagSection: tagSection,
          footer: footer,
          missingCta: missingCta,
          onProcessingChanged: onProcessingChanged,
          onAfterRoute: onAfterRoute,
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = _openInMemory());
  tearDown(() async => db.close());

  group('ClarifyTagSection.draftInputOnly', () {
    testWidgets('renders no tag section', (tester) async {
      final capture = await _insertCapture(db, id: 'x');

      await tester.pumpWidget(
        _card(db, capture, tagSection: ClarifyTagSection.draftInputOnly),
      );
      await _pumpFrames(tester, frames: 5);

      expect(find.text('TAGS'), findsNothing);
      expect(find.byType(ProjectPickerWidget), findsNothing);
      expect(find.byType(ContextTagPickerWidget), findsNothing);
      // The rest of the card is untouched — this is a tag option, not a
      // different surface.
      expect(find.byKey(const Key('clarify_title')), findsOneWidget);
      expect(find.byType(ClarifyEnergyPicker), findsOneWidget);
    });

    testWidgets('the hints still reach the Outcome as draft input',
        (tester) async {
      // Seeded on the Capture and never overridden into a provider, so the
      // only way it can arrive is the one-shot read.
      final capture = await _insertCapture(db, id: 'x');
      await _insertTag(db, id: 'c1', name: 'work', type: 'context');
      await db.captureDao.assignTagHint('x', 'c1', _userId);

      await tester.pumpWidget(
        _card(db, capture, tagSection: ClarifyTagSection.draftInputOnly),
      );
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      final outcomeId = (await db.captureDao.outcomeIdsForCapture('x')).single;
      expect(await _joinedTagIds(db, outcomeId), contains('c1'));
    });

    testWidgets('a person hint is dropped, a context hint is not',
        (tester) async {
      // Both kinds seeded, or the exclusion is unfalsifiable. Delegation is
      // the orthogonal axis and the Waiting For picker is the only thing that
      // writes it.
      final capture = await _insertCapture(db, id: 'x');
      await _insertTag(db, id: 'c1', name: 'work', type: 'context');
      await _insertTag(db, id: 'per1', name: 'Alice', type: 'person');
      await db.captureDao.assignTagHint('x', 'c1', _userId);
      await db.captureDao.assignTagHint('x', 'per1', _userId);

      await tester.pumpWidget(
        _card(db, capture, tagSection: ClarifyTagSection.draftInputOnly),
      );
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      final outcomeId = (await db.captureDao.outcomeIdsForCapture('x')).single;
      final joined = await _joinedTagIds(db, outcomeId);
      expect(joined, contains('c1'));
      expect(joined, isNot(contains('per1')));
    });
  });

  group('ClarifyTagSection.editablePickers', () {
    testWidgets('renders the pickers', (tester) async {
      final capture = await _insertCapture(db, id: 'x');

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.editablePickers,
        tagHintsStream: Stream.value(const <Tag>[]),
      ));
      await _pumpFrames(tester, frames: 5);

      expect(find.text('TAGS'), findsOneWidget);
      expect(find.byType(ProjectPickerWidget), findsOneWidget);
      expect(find.byType(ContextTagPickerWidget), findsOneWidget);
    });

    testWidgets('a tag tapped just before routing still reaches the Outcome',
        (tester) async {
      // The picker's DAO write is unawaited and the hint stream is a frame
      // behind, so only the synchronous draft can carry it.
      final capture = await _insertCapture(db, id: 'x');
      final ctx = await _insertTag(db, id: 'c1', name: 'work', type: 'context');
      final hints = StreamController<List<Tag>>();
      addTearDown(hints.close);
      hints.add(const <Tag>[]);

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.editablePickers,
        contextTags: [ctx],
        tagHintsStream: hints.stream,
      ));
      await _pumpFrames(tester, frames: 5);

      await tester.ensureVisible(find.text('@work'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('@work'));
      await tester.pump();

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      final outcomeId = (await db.captureDao.outcomeIdsForCapture('x')).single;
      expect(await _joinedTagIds(db, outcomeId), contains('c1'));
    });
  });

  group('composition slots', () {
    testWidgets('the footer renders below the action bar in the 1-1 body',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x');

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.draftInputOnly,
        footer: const ClarifyDestinationButton(
          label: 'Skip',
          icon: Icons.next_plan_outlined,
          color: Color(0xFF6B7280),
          onTap: _noop,
        ),
      ));
      await _pumpFrames(tester, frames: 5);

      for (var i = 0; i < 15 && find.text('Skip').evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Skip'), findsOneWidget);
      // Below the bar, not above it: a nav escape hatch is not a verdict, and
      // the ordering is what says so.
      expect(
        tester.getTopLeft(find.text('Skip')).dy,
        greaterThan(tester.getTopLeft(find.text('Discard Capture')).dy),
      );
    });

    testWidgets('no footer means no extra child', (tester) async {
      final capture = await _insertCapture(db, id: 'x');

      await tester.pumpWidget(
        _card(db, capture, tagSection: ClarifyTagSection.draftInputOnly),
      );
      await _pumpFrames(tester, frames: 5);
      for (var i = 0; i < 15; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Skip'), findsNothing);
    });

    testWidgets('missingCta is the way out when the subject is gone',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.draftInputOnly,
        captureStream: feed.stream,
        missingCta: TextButton(onPressed: _noop, child: const Text('Back')),
      ));
      feed.add(capture);
      await _pumpFrames(tester, frames: 5);
      expect(find.text('Back'), findsNothing,
          reason: 'the CTA belongs to the missing state alone');

      feed.add(null);
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
    });

    testWidgets('without a missingCta the missing state offers no exit',
        (tester) async {
      // The ceremony hosts pass none: their step footer already owns Skip, and
      // a second exit there would offer to leave the whole ritual.
      final capture = await _insertCapture(db, id: 'x');
      final feed = StreamController<Capture?>.broadcast();
      addTearDown(feed.close);

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.editablePickers,
        tagHintsStream: Stream.value(const <Tag>[]),
        captureStream: feed.stream,
      ));
      feed.add(capture);
      await _pumpFrames(tester, frames: 5);
      feed.add(null);
      await _pumpFrames(tester, frames: 5);

      expect(find.byKey(const Key('clarify_subject_missing')), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('onProcessingChanged reports true, then false', (tester) async {
      // The *sequence* is the claim. A test that only checks the last value
      // passes against a callback that never fired at all.
      final capture = await _insertCapture(db, id: 'x');
      final gate = Completer<void>();
      final reported = <bool>[];

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.draftInputOnly,
        onProcessingChanged: reported.add,
        clarificationService: _BlockingClarificationService(
          DaoClarificationService(db),
          gate.future,
        ),
      ));
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await tester.pump();

      expect(reported, [true],
          reason: 'the bar is busy and the host has been told');

      gate.complete();
      await _pumpFrames(tester);

      expect(reported, [true, false]);
    });
  });

  group('the body renders no chrome and never pops', () {
    testWidgets('no Scaffold, AppBar or PopScope of its own', (tester) async {
      // Scoped to descendants of the card, and pumped inside a host Scaffold,
      // so the assertion is about the card rather than trivially true.
      final capture = await _insertCapture(db, id: 'x');

      await tester.pumpWidget(
        _card(db, capture, tagSection: ClarifyTagSection.draftInputOnly),
      );
      await _pumpFrames(tester, frames: 5);

      for (final chrome in [Scaffold, AppBar, PopScope]) {
        expect(
          find.descendant(
            of: find.byType(ClarifyCard),
            matching: find.byType(chrome),
          ),
          findsNothing,
          reason: '$chrome belongs to the host — three hosts, three chromes, '
              'zero branches in the body',
        );
      }
    });

    testWidgets('routing does not pop; the host hook is the only exit',
        (tester) async {
      final capture = await _insertCapture(db, id: 'x');
      var hookCalls = 0;

      await tester.pumpWidget(_card(
        db,
        capture,
        tagSection: ClarifyTagSection.draftInputOnly,
        onAfterRoute: (_) async => hookCalls++,
      ));
      await _pumpFrames(tester, frames: 5);

      await _scrollAndTap(tester, 'Next Action');
      await _pumpFrames(tester);

      expect(hookCalls, 1);
      // Still mounted: nothing in the body navigated. Asserted on the card
      // itself, not on a ListView child — the scroll above pushed the title
      // field out of the cache extent, so it is no longer built either way.
      expect(find.byType(ClarifyCard), findsOneWidget);
      expect(find.text('PROCESS TO'), findsOneWidget);
    });
  });
}

void _noop() {}
