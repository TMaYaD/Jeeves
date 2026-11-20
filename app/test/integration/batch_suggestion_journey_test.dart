/// Small same-context tasks are suggested together on the Now timeline (issue
/// #407).
///
/// The real Now screen over a real in-memory database. Nothing moves until the
/// user says "Very good"; "Not today" is remembered for the session.
///
/// Harness shape follows `sprint_on_tile_journey_test.dart`.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// The session opens at 08:00 UTC and the clock reads 08:05, so the day is the
/// same one whatever the host's time zone is.
final _sessionStart = DateTime.utc(2026, 11, 16, 8, 0);
final _now = _sessionStart.add(const Duration(minutes: 5));

Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    // A 45-minute @computer entry first in the Plan, then three @phone errands.
    final plan = <(String, int, String)>[
      ('deep', 45, 'computer'),
      ('call', 10, 'phone'),
      ('book', 10, 'phone'),
      ('text', 5, 'phone'),
    ];
    for (final tag in ['phone', 'computer']) {
      await db.tagDao.upsertTag(TagsCompanion(
        id: Value(tag),
        name: Value('@$tag'),
        type: const Value('context'),
        userId: const Value(_userId),
      ));
    }
    for (final (id, minutes, tag) in plan) {
      await db.todoDao.insertOutcome(
        id: id,
        title: 'Task $id',
        userId: _userId,
        timeEstimate: minutes,
      );
      await seedCurrentAction(db,
          outcomeId: id,
          text: 'Do $id',
          userId: _userId,
          createdAt: _sessionStart);
      await db.into(db.todoTags).insert(TodoTagsCompanion(
            id: Value(todoTagIdFor(id, tag)),
            todoId: Value(id),
            tagId: Value(tag),
            userId: const Value(_userId),
          ));
    }
    await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [for (final (id, _, _) in plan) id],
      now: _sessionStart,
    );
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
  });

  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> openNowScreen(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester, frames: 20);
  }

  Future<Map<String, FocusSessionTask>> planRows(WidgetTester tester) async {
    final rows =
        (await tester.runAsync(() => db.select(db.focusSessionTasks).get()))!;
    return {for (final row in rows) row.taskId: row};
  }

  Future<void> openSuggestion(WidgetTester tester) async {
    final chip = find.byKey(const Key('day_timeline_batch_suggestion_open'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await _pumpFrames(tester);
  }

  testWidgets(
      'the suggestion appears, nothing moves until Very good, and then the '
      'members sit back to back in the gap', (tester) async {
    try {
      await openNowScreen(tester);

      // Only the @phone entries are offered, and nothing is stored yet.
      expect(find.byKey(const Key('day_timeline_batch_suggestion')),
          findsOneWidget);
      expect(find.text('Suggested · @phone'), findsOneWidget);
      var rows = await planRows(tester);
      expect(rows.values.every((row) => row.pinnedStartAt == null), isTrue);
      expect(rows.values.every((row) => row.batchId == null), isTrue);

      await openSuggestion(tester);
      expect(find.text('A small suggestion, sir.'), findsOneWidget);
      expect(find.byKey(const Key('batch_suggestion_member_deep')),
          findsNothing);
      await tester.tap(find.byKey(const Key('batch_suggestion_accept')));
      await _pumpFrames(tester);

      rows = await planRows(tester);
      // Gap start is the end of the 45-minute @computer tile at 08:45.
      expect(rows['call']!.pinnedStartAt?.toUtc(),
          _sessionStart.add(const Duration(minutes: 45)));
      expect(rows['book']!.pinnedStartAt?.toUtc(),
          _sessionStart.add(const Duration(minutes: 55)));
      expect(rows['text']!.pinnedStartAt?.toUtc(),
          _sessionStart.add(const Duration(minutes: 65)));
      final batchIds = {for (final id in ['call', 'book', 'text']) rows[id]!.batchId};
      expect(batchIds.length, 1);
      expect(batchIds.single, isNotNull);
      expect(rows['deep']!.batchId, isNull);
      expect(rows['deep']!.pinnedStartAt, isNull);

      // One tile per Outcome, and the suggestion is gone.
      for (final id in ['call', 'book', 'text']) {
        expect(find.byKey(Key('day_timeline_tile_${id}_1')), findsOneWidget);
      }
      expect(find.byKey(const Key('day_timeline_batch_suggestion')),
          findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets(
      'Edit removes a member: only the remaining entries are pinned and '
      'batched, back to back', (tester) async {
    try {
      await openNowScreen(tester);
      await openSuggestion(tester);
      await tester.tap(find.byKey(const Key('batch_suggestion_edit')));
      await _pumpFrames(tester);
      expect(find.text('Whom shall I include, sir?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('batch_edit_remove_book')));
      await _pumpFrames(tester);
      // The removed entry can be added back; it still fits the gap.
      expect(find.byKey(const Key('batch_edit_add_book')), findsOneWidget);
      await tester.tap(find.byKey(const Key('batch_edit_accept')));
      await _pumpFrames(tester);

      final rows = await planRows(tester);
      expect(rows['call']!.pinnedStartAt?.toUtc(),
          _sessionStart.add(const Duration(minutes: 45)));
      expect(rows['text']!.pinnedStartAt?.toUtc(),
          _sessionStart.add(const Duration(minutes: 55)));
      expect(rows['call']!.batchId, isNotNull);
      expect(rows['call']!.batchId, rows['text']!.batchId);
      expect(rows['book']!.pinnedStartAt, isNull);
      expect(rows['book']!.batchId, isNull);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('Not today is remembered and the suggestion does not return',
      (tester) async {
    try {
      await openNowScreen(tester);
      await openSuggestion(tester);
      await tester.tap(find.byKey(const Key('batch_suggestion_not_today')));
      await _pumpFrames(tester);

      final rows = await planRows(tester);
      for (final id in ['call', 'book', 'text']) {
        expect(rows[id]!.batchSuggestionDeclinedAt, isNotNull);
        expect(rows[id]!.pinnedStartAt, isNull);
      }
      expect(rows['deep']!.batchSuggestionDeclinedAt, isNull);
      expect(find.byKey(const Key('day_timeline_batch_suggestion')),
          findsNothing);
    } finally {
      await teardownApp(tester);
    }
  });
}
