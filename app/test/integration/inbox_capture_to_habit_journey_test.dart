/// Journey: turn an Inbox capture into a Habit (#999).
///
/// The real app router and the real Inbox clarify screen over an in-memory
/// database. Live Drift streams run, so the test pumps bounded frames instead
/// of `pumpAndSettle`.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/providers/clarify_mode_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/screens/habits/habit_flash_banner.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.captureDao.insertCapture(
      CapturesCompanion(
        id: const Value('c1'),
        title: const Value('Stretch every morning'),
        notes: const Value('Hips and back'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    final area = await db.tagDao.findOrCreateTag('Health', 'area', _userId);
    final label = await db.tagDao.findOrCreateTag('home', 'context', _userId);
    await db.captureDao.assignTagHint('c1', area, _userId);
    await db.captureDao.assignTagHint('c1', label, _userId);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await container.read(syncedPreferencesProvider.future);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> openInbox(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    appRouter.go('/inbox');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: appRouter),
      ),
    );
    await _settle(tester);
  }

  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> expectHabitMadeAndCaptureGone(WidgetTester tester) async {
    expect(
      find.byType(HabitFlashBanner),
      findsOneWidget,
      reason: 'the detail opens with the "new" banner',
    );
    expect(find.text('Stretch every morning'), findsWidgets);

    await _settle(tester);
    final result = await tester.runAsync(() async {
      final habits = await db.select(db.habits).get();
      final tags = habits.isEmpty
          ? <Tag>[]
          : await db.habitDao.tagsFor(habits.single.id);
      return (
        habits: habits,
        tags: tags,
        commitments: await db.select(db.habitCommitments).get(),
        todos: await db.select(db.todos).get(),
        capture: await db.captureDao.getCapture('c1'),
      );
    });
    final r = result!;
    expect(r.habits, hasLength(1));
    expect(r.habits.single.title, 'Stretch every morning');
    expect(r.habits.single.notes, 'Hips and back');
    expect(r.tags.map((t) => t.name).toSet(), {'Health', 'home'});
    expect(r.commitments, hasLength(1));
    expect(
      r.commitments.single.repeatKind,
      defaultNewHabitCommitment.repeatKind.storedValue,
    );
    expect(r.todos, isEmpty, reason: 'no Outcome is created');
    expect(r.capture!.clarifiedAt, isNotNull);

    appRouter.pop();
    await _settle(tester);
    expect(
      find.text('Stretch every morning'),
      findsNothing,
      reason:
          'one Back from the Habit lands on the Inbox, without the '
          'capture',
    );
  }

  testWidgets('Make it a Habit from the Inbox clarify screen (1-1)', (
    tester,
  ) async {
    await openInbox(tester);
    try {
      await tester.tap(find.text('Stretch every morning'));
      await _settle(tester);

      await tester.scrollUntilVisible(
        find.text('Make it a Habit'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Make it a Habit'));
      await tester.pump();
      await tester.tap(find.text('Make it a Habit'));
      await _settle(tester);

      await expectHabitMadeAndCaptureGone(tester);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('Make it a Habit is offered in n-m mode too', (tester) async {
    await tester.runAsync(
      () => container
          .read(clarifyModeProvider.notifier)
          .setMode(ClarifyMode.nToM),
    );
    await openInbox(tester);
    try {
      await tester.tap(find.text('Stretch every morning'));
      await _settle(tester);

      await tester.scrollUntilVisible(
        find.text('Make it a Habit'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Make it a Habit'));
      await tester.pump();
      await tester.tap(find.text('Make it a Habit'));
      await _settle(tester);

      await expectHabitMadeAndCaptureGone(tester);
    } finally {
      await closeApp(tester);
    }
  });
}
