/// The Next list that is empty only because everything on it is waiting
/// (issue #1076), over a real in-memory store.
///
/// When time or place hides every Outcome on Next, the list says so and links
/// to the time page and the place page, where the waiting Outcomes are. A
/// Next list with no Outcomes at all keeps the ordinary empty state, and a
/// window that opens brings its Outcome back and takes the state away.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/screens/next/next_empty_state.dart';
import 'package:jeeves/screens/next/next_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Monday to Friday, 09:00 to 17:00.
final _workHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 9 * 60, endMinute: 17 * 60),
};

/// Monday only, 06:00 to 08:00.
final _earlyHours = <int, DayHours>{
  1: (startMinute: 6 * 60, endMinute: 8 * 60),
};

/// Monday to Friday, 18:00 to 20:00.
final _eveningHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 18 * 60, endMinute: 20 * 60),
};

/// Reads through a real-async turn: a Drift query awaited inside a
/// `testWidgets` body would otherwise wait on a clock that never ticks
/// (docs/TESTING.md).
///
/// Only `pump`, never `pumpAndSettle`: the Next list is fed by a live Drift
/// watch, whose pending timer keeps the test binding from ever settling.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Seeds an Outcome with a current Action, and returns the Action's id.
Future<String> _insertOutcome(GtdDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  return (await db.actionDao.getCurrentAction(id))!.id;
}

/// Seeds a named time window.
Future<String> _createWindow(
  GtdDatabase db,
  String name,
  Map<int, DayHours> hours,
) async {
  final id = await db.timeWindowDao.createTimeWindow(
    name: name,
    hours: hours,
    userId: _userId,
  );
  expect(id, isNotNull);
  return id!;
}

/// Seeds an Outcome whose current Action sits in a named time window.
Future<void> _insertWindowedOutcome(
  GtdDatabase db,
  String id,
  String windowId,
) async {
  final actionId = await _insertOutcome(db, id);
  await db.actionDao.setTimeWindow(actionId, windowId);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  late DateTime Function() clock;
  late GoRouter router;
  late ProviderContainer container;
  var containerDisposed = false;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    containerDisposed = false;
    // 2026-11-11 is a Wednesday; 17:00 is just after the work window has
    // closed, and the early and evening windows are shut too.
    clock = () => DateTime(2026, 11, 11, 17, 0);
    router = GoRouter(
      initialLocation: '/next',
      routes: [
        GoRoute(path: '/next', builder: (_, _) => const NextScreen()),
        // The real pages have their own journeys; here they are the way out
        // of the empty state and nothing more.
        GoRoute(
          path: '/time',
          builder: (_, _) => const Scaffold(body: Text('The time page')),
        ),
        GoRoute(
          path: '/places',
          builder: (_, _) => const Scaffold(body: Text('The place page')),
        ),
      ],
    );
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      locationSourceProvider.overrideWithValue(location),
      // With no location, nothing is hidden by place: this journey is about
      // time.
      currentLocationProvider.overrideWith(
          () => FixedLocationNotifier(const LocationUnknown())),
    ]);
  });

  tearDown(() async {
    if (!containerDisposed) {
      containerDisposed = true;
      container.dispose();
    }
    router.dispose();
    await location.dispose();
    await db.close();
  });

  /// The Next screen, over the real store.
  Future<void> pumpNext(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _settle(tester);
  }

  /// Seeds three Outcomes, each in a time window that is closed at the
  /// clock's time.
  Future<void> seedThreeWindowedOutcomes() async {
    final early = await _createWindow(db, 'Early', _earlyHours);
    final work = await _createWindow(db, 'Work hours', _workHours);
    final evening = await _createWindow(db, 'Evening', _eveningHours);
    await _insertWindowedOutcome(db, 'o1', early);
    await _insertWindowedOutcome(db, 'o2', work);
    await _insertWindowedOutcome(db, 'o3', evening);
  }

  /// Runs [body] and disposes the container afterwards, in the body's
  /// `finally`: the boundary timer the container armed must be cancelled
  /// before the test binding checks for pending timers (docs/TESTING.md).
  Future<void> withContainer(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } finally {
      if (!containerDisposed) {
        containerDisposed = true;
        await tester.runAsync(() async {
          container.dispose();
        });
      }
    }
  }

  testWidgets('with every Outcome hidden, the list says so', (tester) async {
    await withContainer(tester, () async {
      await tester.runAsync(seedThreeWindowedOutcomes);
      await pumpNext(tester);

      expect(find.byKey(const Key('next_all_hidden')), findsOneWidget);
      expect(find.text('Nothing on Next'), findsNothing);

      // The line is one of the pool's, so Jeeves does not say the same thing
      // every time.
      final titles = nextAllHiddenPool.map((pair) => pair.$1).toSet();
      final said = tester
          .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('next_all_hidden')),
            matching: find.byType(Text),
          ))
          .map((text) => text.data)
          .toSet();
      expect(said.any(titles.contains), isTrue,
          reason: 'the title is one of the pool');
    });
  });

  testWidgets('the all-hidden line wears the Jeeves-speak treatment',
      (tester) async {
    await withContainer(tester, () async {
      await tester.runAsync(seedThreeWindowedOutcomes);
      await pumpNext(tester);

      // Jeeves's own words, so they get Jeeves's shape: a bold header line
      // over a lighter subtitle (docs/DESIGN.md § Voice).
      final header = tester.widget<Text>(find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            nextAllHiddenPool.any((pair) => pair.$1 == widget.data),
      ));
      expect(header.style?.fontSize, 15);
      expect(header.style?.fontWeight, FontWeight.w700);

      final subtitle = tester.widget<Text>(find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            nextAllHiddenPool.any((pair) => pair.$2 == widget.data),
      ));
      expect(subtitle.style?.fontWeight, FontWeight.w500);
    });
  });

  testWidgets('the empty state links to the time page and the place page',
      (tester) async {
    await withContainer(tester, () async {
      await tester.runAsync(seedThreeWindowedOutcomes);
      await pumpNext(tester);

      await tester.tap(find.byKey(const Key('next_all_hidden_time')));
      await _settle(tester);
      expect(find.text('The time page'), findsOneWidget);

      router.go('/next');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('next_all_hidden_places')));
      await _settle(tester);
      expect(find.text('The place page'), findsOneWidget);
    });
  });

  testWidgets('with no Outcomes at all, the ordinary empty state shows',
      (tester) async {
    await withContainer(tester, () async {
      await pumpNext(tester);

      expect(find.text('Nothing on Next'), findsOneWidget);
      expect(find.byKey(const Key('next_all_hidden')), findsNothing);
    });
  });

  testWidgets('a window that opens brings its Outcome back', (tester) async {
    await withContainer(tester, () async {
      await tester.runAsync(seedThreeWindowedOutcomes);
      await pumpNext(tester);
      expect(find.byKey(const Key('next_all_hidden')), findsOneWidget);

      // Thursday 10:00 — the work window is open, the early and evening ones
      // are not, so exactly one Outcome comes back.
      clock = () => DateTime(2026, 11, 12, 10);
      container.invalidate(timeWindowBoundaryTickProvider);
      await _settle(tester);

      expect(find.text('Outcome o2'), findsOneWidget);
      expect(find.byKey(const Key('next_all_hidden')), findsNothing);
    });
  });
}
