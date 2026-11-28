/// Behavior tests for [DaoClarificationService] (issue #184, Phase 0).
///
/// The service is the single write path for the clarification flow; these
/// tests pin its DB effects on the conflated `todos` schema so the Phase 1/2
/// implementation swap (captures + capture_outcomes) has a contract to
/// preserve at the interface level.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/place_choice.dart';
import 'package:jeeves/models/follow_up_change.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/models/time_choice.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/sync/collection_codecs.dart'
    show
        actionsCollection,
        captureOutcomesCollection,
        capturesCollection,
        placesCollection,
        todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;
import '../test_helpers.dart';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

const _userId = 'test-user';

TodosCompanion _capture({required String id, required String title}) {
  final now = DateTime.now();
  return TodosCompanion(
    id: Value(id),
    title: Value(title),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

CapturesCompanion _captureRow({required String id, required String title}) {
  final now = DateTime.now();
  return CapturesCompanion(
    id: Value(id),
    title: Value(title),
    captureSource: const Value('manual'),
    userId: Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

Future<Todo> _row(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingle();

Future<Todo?> _rowOrNull(GtdDatabase db, String id) =>
    (db.select(db.todos)..where((t) => t.id.equals(id))).getSingleOrNull();

/// The user's named Place, for a test that needs one to point at.
Future<String> _namedPlace(GtdDatabase db, String name) async {
  final id = await db.placeDao.createNamedPlace(
    name: name,
    latitudeDegrees: 51.5,
    longitudeDegrees: -0.12,
    userId: _userId,
  );
  expect(id, isNotNull, reason: 'the named Place must be created');
  return id!;
}

/// A named time window ("Work hours", Monday to Friday), for a test that
/// needs one to point at.
Future<String> _workHoursWindow(GtdDatabase db) async {
  final id = await db.timeWindowDao.createTimeWindow(
    name: 'Work hours',
    hours: {
      for (var day = 1; day <= 5; day++)
        day: (startMinute: 9 * 60, endMinute: 17 * 60),
    },
    userId: _userId,
  );
  expect(id, isNotNull, reason: 'the time window must be created');
  return id!;
}

/// The point the pin tests drop.
final PlaceArea _pinArea =
    PlaceArea.create(latitudeDegrees: 51.5, longitudeDegrees: -0.12)!;

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ClarificationService service;

  setUp(() {
    db = _openInMemory();
    service = DaoClarificationService(db);
  });
  tearDown(() => db.close());

  group('DaoClarificationService', () {
    test('exists reflects row presence', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      expect(await service.exists('a'), isTrue);
      expect(await service.exists('missing'), isFalse);
    });

    test('clarifyToOutcome and stampClarified report false for a vanished Outcome',
        () async {
      expect(
        await service.clarifyToOutcome('missing',
            to: RoutingKind.nextAction, actionText: 'Call Alice'),
        isFalse,
      );
      expect(await service.stampClarified('missing'), isFalse);
      expect(await db.select(db.actions).get(), isEmpty);
    });

    test('clarifyToOutcome and stampClarified report true when they land',
        () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      expect(await service.clarifyToOutcome('a', to: RoutingKind.maybe), isTrue);
      expect(await service.stampClarified('a'), isTrue);
    });

    test('clarifyToOutcome to nextAction routes and stamps', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome(
        'a',
        to: RoutingKind.nextAction,
        actionText: 'Call Alice',
      );

      final row = await _row(db, 'a');
      expect(row.intent, 'next');
      expect((await db.actionDao.getCurrentAction('a'))?.actionText,
          'Call Alice');
      expect(row.lastClarifiedAt, isNotNull);
      expect(row.doneAt, isNull);
    });

    test('clarifyToOutcome to maybe sets intent without done_at', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.maybe);

      final row = await _row(db, 'a');
      expect(row.intent, 'maybe');
      expect(row.doneAt, isNull);
    });

    test('clarifyToOutcome to done stamps Completion', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.done);

      final row = await _row(db, 'a');
      expect(row.doneAt, isNotNull);
    });

    test('clarifyToOutcome to trash sets intent=trash', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.clarifyToOutcome('a', to: RoutingKind.trash);

      final row = await _row(db, 'a');
      expect(row.intent, 'trash');
    });

    test('clarifyToOutcome to waitingFor replaces person tags', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('alice-tag'),
        name: Value('Alice'),
        type: Value('person'),
        userId: Value(_userId),
      ));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('bob-tag'),
        name: Value('Bob'),
        type: Value('person'),
        userId: Value(_userId),
      ));
      // Pre-existing delegate: the routing below must replace it, not
      // append to it.
      await db.tagDao.assignTag('a', 'bob-tag', _userId);
      expect(await service.getPersonTagIds('a'), {'bob-tag'});

      await service.clarifyToOutcome(
        'a',
        to: RoutingKind.waitingFor,
        personTagIds: {'alice-tag'},
        userId: _userId,
      );

      final row = await _row(db, 'a');
      expect(row.intent, 'next');
      expect(await service.getPersonTagIds('a'), {'alice-tag'});
    });

    test('completeOutcome stamps done_at and last_clarified_at', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.completeOutcome('a');

      final row = await _row(db, 'a');
      expect(row.doneAt, isNotNull);
      expect(row.lastClarifiedAt, isNotNull);
    });

    test('completeCurrentAction ends the Action without completing or '
        'stamping the Outcome', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));
      await db.todoDao.setCurrentActionText('a', 'call the plumber');
      final clarifiedAt = (await _row(db, 'a')).lastClarifiedAt;

      await service.completeCurrentAction('a');

      final row = await _row(db, 'a');
      expect(row.doneAt, isNull, reason: 'the Outcome is not achieved');
      expect(row.lastClarifiedAt, clarifiedAt,
          reason: 'completion is engagement, not clarification');
      expect(await db.actionDao.getCurrentAction('a'), isNull);
    });

    test('stampClarified touches only the clarification timestamp', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.stampClarified('a');

      final row = await _row(db, 'a');
      expect(row.lastClarifiedAt, isNotNull);
      expect(row.title, 'Item');
    });

    test('updateFields writes edits and honors clear flags', () async {
      await db.into(db.todos).insert(_capture(id: 'a', title: 'Item'));

      await service.updateFields(
        'a',
        title: 'Renamed',
        notes: 'Some context',
        energyLevel: 'high',
        timeEstimate: 30,
        dueDate: DateTime.utc(2026, 8, 1),
      );

      var row = await _row(db, 'a');
      expect(row.title, 'Renamed');
      expect(row.notes, 'Some context');
      expect(row.energyLevel, 'high');
      expect(row.timeEstimate, 30);
      expect(row.dueDate, isNotNull);
      // A non-no-op edit is a clarifying micro-act and must stamp.
      expect(row.lastClarifiedAt, isNotNull);

      await service.updateFields(
        'a',
        clearEnergyLevel: true,
        clearTimeEstimate: true,
        clearDueDate: true,
      );

      row = await _row(db, 'a');
      expect(row.energyLevel, isNull);
      expect(row.timeEstimate, isNull);
      expect(row.dueDate, isNull);
    });
  });

  group('clarifyCaptureToOutcome (Capture → new Outcome)', () {
    test('creates a routed Outcome, links it, and stamps the Capture',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Draft'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Draft outline',
        action: const ActionDraft(text: 'Draft outline'),
      );

      // A distinct Outcome row exists — the Capture is not flipped in place.
      final outcome = await _row(db, outcomeId);
      expect(outcome.id, isNot('c1'));
      expect(outcome.title, 'Draft outline');
      expect(outcome.intent, 'next');
      expect((await db.actionDao.getCurrentAction(outcomeId))?.actionText,
          'Draft outline');
      expect(outcome.lastClarifiedAt, isNotNull);

      // Provenance link + Capture stamped out of the Inbox.
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [outcomeId]);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      // The raw fragment persists as provenance, unmutated.
      expect((await db.captureDao.getCapture('c1'))!.title, 'Draft');
    });

    test('carries draft fields and tag ids onto the Outcome', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Idea'));
      final work = await db.tagDao.findOrCreateTag('work', 'context', _userId);

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Renamed',
        notes: 'Context',
        // Effort travels on the Action grain now; on this Next route the
        // phrase mints the birth Action, which seeds from the columns
        // insertOutcome just wrote (D3).
        action: const ActionDraft(
          text: 'Renamed',
          energyLevel: 'high',
          timeEstimateMinutes: 30,
        ),
        dueDate: DateTime.utc(2026, 8, 1),
        tagIds: {work},
      );

      final outcome = await _row(db, outcomeId);
      expect(outcome.notes, 'Context');
      expect(outcome.energyLevel, 'high');
      expect(outcome.timeEstimate, 30);
      expect(outcome.dueDate?.toUtc(), DateTime.utc(2026, 8, 1));
      final tagRows = await (db.select(db.todoTags)
            ..where((tt) => tt.todoId.equals(outcomeId)))
          .get();
      expect(tagRows.map((r) => r.tagId), [work]);
    });

    test('waitingFor attaches the delegate person tag', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Ask Bob'));
      await db.tagDao.upsertTag(const TagsCompanion(
        id: Value('bob-tag'),
        name: Value('Bob'),
        type: Value('person'),
        userId: Value(_userId),
      ));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.waitingFor,
        userId: _userId,
        title: 'Ask Bob to review',
        personTagIds: {'bob-tag'},
      );

      expect(await db.todoDao.getPersonTagIdsForTodo(outcomeId), {'bob-tag'});
      expect((await _row(db, outcomeId)).intent, 'next');
    });

    test('done routing stamps Completion on the new Outcome', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Quick'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.done,
        userId: _userId,
        title: 'Quick win',
      );

      expect((await _row(db, outcomeId)).doneAt, isNotNull);
    });

    test('normalises an injected non-UTC timestamp to UTC on the Outcome',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      // A local (non-UTC) wall-clock time — the clarify card supplies one.
      final localNow = DateTime(2026, 8, 1, 9, 30);
      expect(localNow.isUtc, isFalse);

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
        now: localNow,
      );

      final outcome = await _row(db, outcomeId);
      // Every timestamp column must land in UTC, not just last_clarified_at:
      // the op log's canonical instant form is ISO-8601 UTC to the millisecond
      // (`FieldKind.instant` / `encodeInstant`), so a column holding local
      // wall-clock time would encode to a different instant than it names.
      expect(outcome.createdAt.isUtc, isTrue);
      expect(outcome.createdAt, localNow.toUtc());
      expect(outcome.updatedAt!.isUtc, isTrue);
      expect(outcome.updatedAt, localNow.toUtc());
      expect(outcome.lastClarifiedAt!.isUtc, isTrue);
    });

    test('throws and creates nothing when the Capture is gone', () async {
      // No Capture 'missing' exists.
      await expectLater(
        service.clarifyCaptureToOutcome(
          'missing',
          to: RoutingKind.nextAction,
          userId: _userId,
          title: 'Orphan',
          outcomeId: 'o-orphan',
        ),
        throwsA(isA<CaptureNotFoundError>()),
      );
      // The transaction rolled back — no orphan Outcome or link persisted.
      expect(await _rowOrNull(db, 'o-orphan'), isNull);
      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.select(db.captureOutcomes).get(), isEmpty);
    });

    test('rejects trash — discard is zero-Outcome, not a trashed Outcome',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Noise'));

      await expectLater(
        service.clarifyCaptureToOutcome(
          'c1',
          to: RoutingKind.trash,
          userId: _userId,
          title: 'Noise',
          outcomeId: 'o-trash',
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Nothing was minted and the Capture stayed in the Inbox. Routing a
      // Capture to Trash is [discardCapture]'s job (stamp only, zero
      // Outcomes); creating an Outcome just to mark it trashed would put a
      // phantom row on the Trash List and record a provenance link to work
      // that was never done. A caller that gets this wrong fails loudly
      // rather than half-clarifying the Capture.
      expect(await _rowOrNull(db, 'o-trash'), isNull);
      expect(await db.select(db.todos).get(), isEmpty);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    });

    test('re-route overwrites the session Outcome (Ceremony Back → re-tap)',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));

      final first = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
      );
      final second = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.maybe,
        userId: _userId,
        title: 'Item',
      );

      // The first Outcome is gone; exactly one link remains, to the second.
      expect(await _rowOrNull(db, first), isNull);
      expect(first, isNot(second));
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [second]);
      expect((await _row(db, second)).intent, 'maybe');
    });

    test('re-route keeps an Outcome another Capture still claims (merge)',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'One'));
      await db.captureDao.insertCapture(_captureRow(id: 'c2', title: 'Two'));

      final shared = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Shared work',
      );
      // A second Capture merges into the same Outcome (many-to-many).
      await db.captureDao.linkOutcome('c2', shared, _userId);

      // Re-routing c1 must retract only c1's claim, never delete the shared row.
      final fresh = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.maybe,
        userId: _userId,
        title: 'Shared work',
      );

      expect(fresh, isNot(shared));
      expect(await _rowOrNull(db, shared), isNotNull,
          reason: 'c2 still claims it — must survive');
      expect(await db.captureDao.captureIdsForOutcome(shared), ['c2']);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), [fresh]);
    });

    test('to Next puts the draft\'s named place on the Action it mints',
        () async {
      final ts = DateTime.utc(2026, 8, 1, 9);
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Buy hinges'));
      final placeId = await _namedPlace(db, 'Hardware store');

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Buy hinges',
        action: ActionDraft(
          text: 'Buy hinges',
          place: NamedPlaceDraft(placeId, 'Hardware store'),
        ),
        now: ts,
      );

      final action = await db.actionDao.getCurrentAction(outcomeId);
      expect(action!.placeId, placeId);
      // The named Place itself is untouched: the Action points at it.
      final place = await (db.select(db.places)
            ..where((p) => p.id.equals(placeId)))
          .getSingle();
      expect(place.kind, 'named');
      expect(place.name, 'Hardware store');

      // A Place is not a clarifying act, so the Outcome's stamp is the one the
      // routing wrote — the same one a clarify without a place gets.
      await db.captureDao.insertCapture(_captureRow(id: 'c2', title: 'Other'));
      final plain = await service.clarifyCaptureToOutcome(
        'c2',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Other',
        action: const ActionDraft(text: 'Other'),
        now: ts,
      );
      expect((await _row(db, outcomeId)).lastClarifiedAt,
          (await _row(db, plain)).lastClarifiedAt);
    });

    test('to Next with a pin creates the pin and points the Action at it',
        () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Buy hinges'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Buy hinges',
        action: ActionDraft(
          text: 'Buy hinges',
          place: PinDraft(area: _pinArea, name: 'Corner shop'),
        ),
      );

      final action = await db.actionDao.getCurrentAction(outcomeId);
      final pinId = action!.placeId!;
      final pin =
          await (db.select(db.places)..where((p) => p.id.equals(pinId))).getSingle();
      expect(pin.kind, 'pin');
      expect(pin.name, 'Corner shop');
      expect(pin.latitudeMicrodegrees, _pinArea.latitudeMicrodegrees);
      expect(pin.longitudeMicrodegrees, _pinArea.longitudeMicrodegrees);
      expect(pin.radiusMeters, _pinArea.radiusMeters);
      // A pin belongs to the one Action that points at it: it is never listed.
      expect(await db.placeDao.watchNamedPlaces().first, isEmpty);
    });

    test('to Waiting For carries the place onto the Action', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Ask Bob'));
      final placeId = await _namedPlace(db, 'Hardware store');

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.waitingFor,
        userId: _userId,
        title: 'Ask Bob',
        action: ActionDraft(
          text: 'Ask Bob',
          place: NamedPlaceDraft(placeId, 'Hardware store'),
        ),
      );

      expect((await db.actionDao.getCurrentAction(outcomeId))!.placeId, placeId);
    });

    test('to Maybe drops the place — no Place row is written', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Someday'));

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.maybe,
        userId: _userId,
        title: 'Someday',
        action: ActionDraft(
          text: 'Someday',
          place: PinDraft(area: _pinArea, name: 'Corner shop'),
        ),
      );

      // Only the Next and Waiting For arms mint an Action, so there is
      // nothing for the Place to ride on and nothing is written.
      expect(await db.select(db.places).get(), isEmpty);
      expect(await db.actionDao.getCurrentAction(outcomeId), isNull);
      // The Outcome is made as before.
      expect((await _row(db, outcomeId)).intent, 'maybe');
    });

    test('a Capture that is gone mid-clarify leaves no pin behind', () async {
      await expectLater(
        service.clarifyCaptureToOutcome(
          'missing',
          to: RoutingKind.nextAction,
          userId: _userId,
          title: 'Orphan',
          action: ActionDraft(
            text: 'Orphan',
            place: PinDraft(area: _pinArea, name: 'Corner shop'),
          ),
        ),
        throwsA(isA<CaptureNotFoundError>()),
      );

      // The throw rolls the whole transaction back — the pin went with it.
      expect(await db.select(db.places).get(), isEmpty);
      expect(await db.select(db.actions).get(), isEmpty);
    });

    test('a named place deleted before the verdict lands the Outcome without '
        'one', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Buy hinges'));
      final placeId = await _namedPlace(db, 'Hardware store');
      await db.placeDao.deletePlace(placeId);

      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Buy hinges',
        action: ActionDraft(
          text: 'Buy hinges',
          place: NamedPlaceDraft(placeId, 'Hardware store'),
        ),
      );

      // A Place that no longer exists is refused rather than stored as a
      // reference to nothing — and the clarify still lands.
      expect((await db.actionDao.getCurrentAction(outcomeId))!.placeId, isNull);
      expect((await _row(db, outcomeId)).title, 'Buy hinges');
    });


    group('the draft\'s time', () {
      Future<String> clarify(
        RoutingKind to,
        ActionTimeDraft? time, {
        FollowUpChange? followUp,
      }) async {
        await db.captureDao
            .insertCapture(_captureRow(id: 'c1', title: 'Buy hinges'));
        return service.clarifyCaptureToOutcome(
          'c1',
          to: to,
          userId: _userId,
          title: 'Buy hinges',
          action: ActionDraft(text: 'Buy hinges', time: time),
          followUp: followUp,
        );
      }

      test('to Next puts a named window on the Action it mints', () async {
        final windowId = await _workHoursWindow(db);
        final outcomeId =
            await clarify(RoutingKind.nextAction, TimeWindowDraft(windowId));

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(action!.timeWindowId, windowId);
        expect(action.timeContext, isNull);
      });

      test('to Next puts a one-time time on the Action it mints', () async {
        final value = TimeContext.create(
          fromDate: DateTime(2026, 12, 1),
          days: {6, 7},
          startMinute: 9 * 60,
          endMinute: 12 * 60,
        )!;
        final outcomeId =
            await clarify(RoutingKind.nextAction, OneTimeDraft(value));

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(TimeContext.tryParse(action!.timeContext), value);
        expect(action.timeWindowId, isNull);
      });

      test('with no time the Action carries none', () async {
        final outcomeId = await clarify(RoutingKind.nextAction, null);

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(action!.timeWindowId, isNull);
        expect(action.timeContext, isNull);
      });

      test('to Someday drops the time', () async {
        final windowId = await _workHoursWindow(db);
        final outcomeId =
            await clarify(RoutingKind.maybe, TimeWindowDraft(windowId));

        expect(await db.actionDao.getCurrentAction(outcomeId), isNull);
        expect(await db.select(db.actions).get(), isEmpty);
      });

      test('a window deleted before the verdict lands the Outcome without '
          'a time', () async {
        final windowId = await _workHoursWindow(db);
        await db.timeWindowDao.deleteTimeWindow(windowId);

        final outcomeId =
            await clarify(RoutingKind.nextAction, TimeWindowDraft(windowId));

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(action!.timeWindowId, isNull);
        expect((await _row(db, outcomeId)).title, 'Buy hinges');
      });

      test('to Waiting For with a follow-up date: a one-time time keeps its '
          'days and hours and takes the date as its From', () async {
        final outcomeId = await clarify(
          RoutingKind.waitingFor,
          OneTimeDraft(TimeContext.create(
            fromDate: DateTime(2026, 12, 1),
            days: {1, 2},
            startMinute: 9 * 60,
            endMinute: 17 * 60,
          )!),
          followUp: FollowUpChange.set(DateTime(2026, 12, 10)),
        );

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(
          TimeContext.tryParse(action!.timeContext),
          TimeContext.create(
            fromDate: DateTime(2026, 12, 10),
            days: {1, 2},
            startMinute: 9 * 60,
            endMinute: 17 * 60,
          ),
        );
      });

      test('to Waiting For with a follow-up date: a named window is not '
          'written and the date is kept', () async {
        final windowId = await _workHoursWindow(db);
        final outcomeId = await clarify(
          RoutingKind.waitingFor,
          TimeWindowDraft(windowId),
          followUp: FollowUpChange.set(DateTime(2026, 12, 10)),
        );

        final action = await db.actionDao.getCurrentAction(outcomeId);
        expect(action!.timeWindowId, isNull);
        expect(
          TimeContext.tryParse(action.timeContext),
          TimeContext.create(fromDate: DateTime(2026, 12, 10)),
        );
      });

      test('to Waiting For without a follow-up date takes the window',
          () async {
        final windowId = await _workHoursWindow(db);
        final outcomeId =
            await clarify(RoutingKind.waitingFor, TimeWindowDraft(windowId));

        expect(
            (await db.actionDao.getCurrentAction(outcomeId))!.timeWindowId,
            windowId);
      });

      test('the Capture row is unchanged by the time', () async {
        final windowId = await _workHoursWindow(db);
        await db.captureDao
            .insertCapture(_captureRow(id: 'c1', title: 'Buy hinges'));
        final before = await db.captureDao.getCapture('c1');
        await service.clarifyCaptureToOutcome(
          'c1',
          to: RoutingKind.nextAction,
          userId: _userId,
          title: 'Buy hinges',
          action: ActionDraft(
              text: 'Buy hinges', time: TimeWindowDraft(windowId)),
        );
        final after = await db.captureDao.getCapture('c1');
        expect(after!.title, before!.title);
        expect(after.notes, before.notes);
      });
    });

    test('the Capture keeps exactly what was captured', () async {
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Buy hinges'),
        notes: const Value('the blue ones'),
        captureSource: const Value('manual'),
        userId: const Value(_userId),
        createdAt: Value(DateTime.utc(2026, 8, 1, 8)),
        updatedAt: Value(DateTime.utc(2026, 8, 1, 8)),
      ));
      final tag = await db.tagDao.findOrCreateTag('hardware', 'context', _userId);
      await db.captureDao.assignTagHint('c1', tag, _userId);

      await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Buy hinges',
        action: ActionDraft(
          text: 'Buy hinges',
          place: PinDraft(area: _pinArea, name: 'Corner shop'),
        ),
      );

      final capture = await db.captureDao.getCapture('c1');
      expect(capture!.title, 'Buy hinges');
      expect(capture.notes, 'the blue ones');
      final hints = await (db.select(db.captureTags)
            ..where((t) => t.captureId.equals('c1')))
          .get();
      expect(hints.map((t) => t.tagId), [tag]);
    });
  });

  group('discardCapture (zero-Outcome clarification)', () {
    test('stamps the Capture and creates nothing', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Noise'));

      await service.discardCapture('c1');

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      // No Outcome fabricated on the todos table.
      final todoCount = await db.select(db.todos).get();
      expect(todoCount, isEmpty);
    });

    test('throws when the Capture is gone', () async {
      await expectLater(
        service.discardCapture('missing'),
        throwsA(isA<CaptureNotFoundError>()),
      );
    });

    test('drops a session Outcome carved before the discard', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      final outcomeId = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Item',
      );

      await service.discardCapture('c1');

      expect(await _rowOrNull(db, outcomeId), isNull);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    });

    test('keeps an Outcome another Capture still claims (merge)', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'One'));
      await db.captureDao.insertCapture(_captureRow(id: 'c2', title: 'Two'));
      final shared = await service.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Shared work',
      );
      await db.captureDao.linkOutcome('c2', shared, _userId);

      await service.discardCapture('c1');

      expect(await _rowOrNull(db, shared), isNotNull,
          reason: 'c2 still claims it — discard must only unlink');
      expect(await db.captureDao.captureIdsForOutcome(shared), ['c2']);
      expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    });
  });

  group('captureExists', () {
    test('reflects Capture presence', () async {
      await db.captureDao.insertCapture(_captureRow(id: 'c1', title: 'Item'));
      expect(await service.captureExists('c1'), isTrue);
      expect(await service.captureExists('missing'), isFalse);
    });
  });

  group('clarificationServiceProvider', () {
    test('resolves to the DAO-backed implementation', () {
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(
        container.read(clarificationServiceProvider),
        isA<DaoClarificationService>(),
      );
    });
  });

  // T4 — the service seam is one capturing scope: a committed method emits one
  // coalesced op per entity (not one per DAO call), and a rolled-back method
  // emits none and writes nothing.
  group('capture contract (op emission per service call)', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase captureDb;
    late ClarificationService captureService;

    setUp(() {
      capture = RecordingDomainOpCapture();
      captureDb = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
      captureService = DaoClarificationService(captureDb);
    });
    tearDown(() => captureDb.close());

    test('clarifyCaptureToOutcome emits exactly one op per touched entity',
        () async {
      await captureDb.captureDao.insertCapture(
        _captureRow(id: 'c1', title: 'Draft'),
      );
      capture.clear();

      await captureService.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Draft outline',
        action: const ActionDraft(text: 'Draft outline'),
      );

      // insertOutcome + applyRouting both write `todos`; pre-fix each DAO's own
      // scope was outermost and emitted separately, so `todos` was authored
      // twice. One capturing scope coalesces them to a single op — the
      // deliberate behavioral change, convergence-identical (one HLC per net
      // effect).
      expect(capture.forCollection(todosCollection), hasLength(1),
          reason: 'the two todos writes coalesce to one op');
      expect(capture.forCollection(actionsCollection), hasLength(1));
      expect(capture.forCollection(captureOutcomesCollection), hasLength(1));
      expect(capture.forCollection(capturesCollection), hasLength(1));
      // No entity is authored more than once.
      expect(capture.keys.toSet(), hasLength(capture.keys.length),
          reason: 'exactly one coalesced op per entity');
    });

    test('a clarify with a pin authors one pin op and points the Action op at '
        'it', () async {
      await captureDb.captureDao.insertCapture(
        _captureRow(id: 'c1', title: 'Draft'),
      );
      capture.clear();

      await captureService.clarifyCaptureToOutcome(
        'c1',
        to: RoutingKind.nextAction,
        userId: _userId,
        title: 'Draft outline',
        action: ActionDraft(
          text: 'Draft outline',
          place: PinDraft(area: _pinArea, name: 'Corner shop'),
        ),
      );

      // The pin is an entity of its own: one op for its `places` row.
      final placeOps = capture.forCollection(placesCollection);
      expect(placeOps, hasLength(1));
      expect(placeOps.single.fields['kind'], 'pin');
      expect(placeOps.single.fields['name'], 'Corner shop');

      // The Action op carries the pin it now points at — one op for the
      // Action, not one for each write that touched it.
      final actionOps = capture.forCollection(actionsCollection);
      expect(actionOps, hasLength(1));
      expect(actionOps.single.fields['place_id'], placeOps.single.entityId);

      // No entity is authored more than once.
      expect(capture.keys.toSet(), hasLength(capture.keys.length),
          reason: 'exactly one coalesced op per entity');
    });

    test('a rolled-back service method authors nothing and writes nothing',
        () async {
      await captureDb.captureDao.insertCapture(
        _captureRow(id: 'c1', title: 'Present'),
      );
      capture.clear();

      // The Outcome vanished between the snapshot pick and the write: the
      // in-transaction guard throws, the whole capturing scope rolls back.
      await expectLater(
        captureService.mergeIntoOutcome('c1', 'gone', userId: _userId),
        throwsStateError,
      );

      expect(capture.recorded, isEmpty,
          reason: 'a rolled-back write is never signed');
      expect(await captureDb.select(captureDb.captureOutcomes).get(), isEmpty,
          reason: 'no link row survives the rollback');
    });
  });
}
