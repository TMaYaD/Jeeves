/// Widget tests for the clarify card's Place chip (issue #1078).
///
/// The chip is the Capture shape's own field: it says where the Action a
/// clarification creates happens. An Outcome already carries its Place and
/// re-clarifying edits it in place, so the chip is absent there.
///
/// **Its own file, deliberately.** The card's live subject binding and the
/// tag pickers behind it read drift streams, and a watch left open when the
/// tree goes leaves a timer pending that the *next* test pays for. A file of
/// its own keeps that trap away from the tests that share the card's other
/// behaviour — and every test here takes the card off screen when it is
/// done, so it leaves nothing behind either (docs/TESTING.md).
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/place_dao.dart' show NamedPlaceWithUse;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/models/follow_up_change.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/place_choice.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_permission_flow.dart';
import 'package:jeeves/providers/places_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/widgets/clarify_card.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../test_helpers.dart';

const _userId = 'local';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

Future<Capture> _insertCapture(
  GtdDatabase db, {
  required String id,
  String title = 'Buy hinges',
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

Future<Todo> _insertOutcome(
  GtdDatabase db, {
  required String id,
  String title = 'Buy hinges',
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        captureSource: const Value('manual'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  return (await db.todoDao.getTodo(id))!;
}

/// Pumps a bounded number of frames instead of [WidgetTester.pumpAndSettle].
///
/// The Capture clarify path writes through the real Drift database, and each
/// write keeps drift's StreamQueryStore emitting, so `pumpAndSettle` never
/// reaches a quiet frame (docs/TESTING.md).
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Takes the card off screen when the test is done.
///
/// The card's live binding is a drift watch, and a watch that is still open
/// when the tree goes leaves a timer pending — which the *next* test would
/// pay for. Unmounting here and pumping twice closes the watch and lets the
/// timer run, so this test leaves nothing behind.
Future<void> _closeCard(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pump(const Duration(milliseconds: 10));
}

/// A viewport tall enough for the whole card to fit.
///
/// The chip sits below the fold on a phone-sized screen, and a ListView
/// builds its children lazily — so a test that scrolls to reach the chip
/// also rebuilds the card's other children, and the watches behind them
/// leave a timer behind. A tall viewport says the chip is there (or is not)
/// without moving anything.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A [ClarificationService] that remembers the Action draft it was handed.
///
/// The write itself is the production one, so the test asserts on what the
/// card passed down rather than on a stand-in's behaviour.
class _RecordingClarificationService extends DaoClarificationService {
  _RecordingClarificationService(super.db);

  /// The Action the last Capture clarification carried.
  ActionDraft? recordedAction;

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
    FollowUpChange? followUp,
    Set<String> tagIds = const {},
    String? outcomeId,
    DateTime? now,
  }) {
    recordedAction = action;
    return super.clarifyCaptureToOutcome(
      captureId,
      to: to,
      userId: userId,
      title: title,
      notes: notes,
      dueDate: dueDate,
      action: action,
      personTagIds: personTagIds,
      followUp: followUp,
      tagIds: tagIds,
      outcomeId: outcomeId,
      now: now,
    );
  }
}

/// The named Place the picker offers.
NamedPlaceWithUse _hardwareStore() => (
      id: 'p1',
      name: 'Hardware store',
      area: PlaceArea.create(
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
      )!,
      useCount: 0,
      hoursLabel: null,
      hours: (timeWindowId: null, ownHoursText: null, timeZone: null),
    );

/// A Capture card in whichever configuration a test is exercising.
Widget _captureCard(
  GtdDatabase db, {
  required Capture capture,
  List<NamedPlaceWithUse> namedPlaces = const <NamedPlaceWithUse>[],
  ClarificationService? clarificationService,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // Static streams, so the card's live binding and the pickers' tag
      // catalogues do not subscribe to a live drift watch and leave a
      // pending timer behind on dispose (docs/TESTING.md).
      captureProvider(capture.id).overrideWith((_) => Stream.value(capture)),
      captureTagHintsProvider(capture.id)
          .overrideWith((_) => Stream.value(const <Tag>[])),
      namedPlacesWithUseCountProvider
          .overrideWith((_) => Stream.value(namedPlaces)),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsWithCountProvider
          .overrideWith((_) => Stream.value(const <TagWithCount>[])),
      projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      if (clarificationService != null)
        clarificationServiceProvider.overrideWithValue(clarificationService),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ClarifyCard.forCapture(
          captureId: capture.id,
          tagSection: ClarifyTagSection.editablePickers,
        ),
      ),
    ),
  );
}

/// The re-clarify shape: an Outcome that has already been through the flow.
Widget _outcomeCard(
  GtdDatabase db, {
  required Todo todo,
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      taskDetailTodoProvider(todo.id).overrideWith((_) => Stream.value(todo)),
      taskTagsProvider(todo.id)
          .overrideWith((_) => Stream.value(const <Tag>[])),
      personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
      contextTagsWithCountProvider
          .overrideWith((_) => Stream.value(const <TagWithCount>[])),
      projectTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ClarifyCard.forOutcome(todoId: todo.id),
      ),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    // The location was asked for on this device already, so a pin does not
    // raise a dialog the card has no business raising.
    SharedPreferences.setMockInitialValues({locationPermissionAskedKey: true});
    db = _openInMemory();
  });
  tearDown(() async => db.close());

  testWidgets('the chip shows on a Capture', (tester) async {
    _useTallViewport(tester);
    final capture = await _insertCapture(db, id: 'x');

    await tester.pumpWidget(
      _captureCard(db, capture: capture),
    );
    await _pumpFrames(tester);

    expect(find.byKey(const Key('clarify_place_chip')), findsOneWidget);
    expect(find.text('Place'), findsOneWidget);

    await _closeCard(tester);
  });

  testWidgets('the chip does not show when re-clarifying an Outcome',
      (tester) async {
    // An Outcome already carries its Place: the chip on the card would be a
    // second place to set the same thing.
    _useTallViewport(tester);
    final todo = await _insertOutcome(db, id: 'o1');

    await tester.pumpWidget(_outcomeCard(db, todo: todo));
    await _pumpFrames(tester);

    // The whole card is on screen, so "not there" means "not in the card".
    expect(find.text('PROCESS TO'), findsOneWidget);
    expect(find.byKey(const Key('clarify_place_chip')), findsNothing);

    await _closeCard(tester);
  });

  testWidgets('choosing a named Place names the chip, and clearing it brings '
      'the label back', (tester) async {
    _useTallViewport(tester);
    final capture = await _insertCapture(db, id: 'x');

    await tester.pumpWidget(
      _captureCard(db, capture: capture, namedPlaces: [_hardwareStore()]),
    );
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const Key('clarify_place_chip')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('place_picker_place_p1')));
    await _pumpFrames(tester);

    expect(find.text('Hardware store'), findsOneWidget);

    // Clear it: the chip is quiet again.
    await tester.tap(find.byKey(const Key('clarify_place_chip')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('place_picker_clear')));
    await _pumpFrames(tester);

    expect(find.text('Place'), findsOneWidget);
    expect(find.text('Hardware store'), findsNothing);

    await _closeCard(tester);
  });

  testWidgets('the chosen Place rides the Action the clarification creates',
      (tester) async {
    _useTallViewport(tester);
    final capture = await _insertCapture(db, id: 'x');
    final service = _RecordingClarificationService(db);

    await tester.pumpWidget(_captureCard(
      db,
      capture: capture,
      namedPlaces: [_hardwareStore()],
      clarificationService: service,
    ));
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const Key('clarify_place_chip')));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('place_picker_place_p1')));
    await _pumpFrames(tester);

    // Route the Capture to Next, accepting the dialog's seeded phrase.
    await tester.tap(find.text('Next Action'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Save'));
    await _pumpFrames(tester);

    final place = service.recordedAction?.place;
    expect(place, isA<NamedPlaceDraft>());
    expect((place! as NamedPlaceDraft).placeId, 'p1');

    await _closeCard(tester);
  });

  testWidgets('an untouched chip leaves the Action without a Place',
      (tester) async {
    _useTallViewport(tester);
    final capture = await _insertCapture(db, id: 'x');
    final service = _RecordingClarificationService(db);

    await tester.pumpWidget(_captureCard(
      db,
      capture: capture,
      namedPlaces: [_hardwareStore()],
      clarificationService: service,
    ));
    await _pumpFrames(tester);

    await tester.tap(find.text('Next Action'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Save'));
    await _pumpFrames(tester);

    expect(service.recordedAction?.place, isNull);

    await _closeCard(tester);
  });
}
