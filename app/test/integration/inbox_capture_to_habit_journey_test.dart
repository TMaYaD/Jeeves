/// Journey: turn an Inbox capture into a Habit (#999).
///
/// The real app router on `/inbox`, over a real in-memory database. The user
/// opens a capture's clarify screen, taps **Make it a Habit**, lands on the
/// new Habit's detail, and backing out shows an Inbox without the capture.
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
import 'package:jeeves/screens/habits/habit_detail_pane.dart';
import 'package:jeeves/screens/inbox/inbox_clarify_screen.dart';

import '../test_helpers.dart';

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  Future<void> seed() async {
    final now = DateTime.now();
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('c1'),
      title: const Value('Meditate'),
      userId: const Value('local'),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    for (final (id, name, type) in [
      ('ctx', 'Home', 'context'),
      ('area', 'Health', 'area'),
    ]) {
      await db.into(db.tags).insert(TagsCompanion(
            id: Value(id),
            name: Value(name),
            type: Value(type),
            userId: const Value('local'),
          ));
      await db.captureDao.assignTagHint('c1', id, 'local');
    }
  }

  Future<void> open(WidgetTester tester, {ClarifyMode? mode}) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await container.read(syncedPreferencesProvider.future);
    if (mode != null) {
      await container.read(clarifyModeProvider.notifier).setMode(mode);
    }
    await seed();
    appRouter.go('/inbox');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    await _flush(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await pumpEventQueue();
      await db.close();
    });
  }

  Future<void> journey(WidgetTester tester) async {
    await tester.tap(find.text('Meditate'));
    await _flush(tester);
    expect(find.byType(InboxClarifyScreen), findsOneWidget);

    final button = find.text('Make it a Habit');
    await tester.scrollUntilVisible(button, 200,
        scrollable: find
            .descendant(
              of: find.byType(InboxClarifyScreen),
              matching: find.byType(Scrollable),
            )
            .first);
    await tester.tap(button);
    await _flush(tester);

    expect(find.byType(InboxClarifyScreen), findsNothing);
    expect(find.byType(HabitDetailScreen), findsOneWidget);
    expect(find.text('Meditate'), findsWidgets);
    expect(find.byKey(const Key('habit_flash_banner')), findsOneWidget);

    final habits = (await tester.runAsync(() => db.select(db.habits).get()))!;
    expect(habits, hasLength(1));
    expect(habits.single.title, 'Meditate');
    final habitId = habits.single.id;
    final tags = (await tester.runAsync(() => db.habitDao.tagsFor(habitId)))!;
    expect(tags.map((t) => t.id).toSet(), {'ctx', 'area'});
    final commitments =
        (await tester.runAsync(() => db.habitDao.commitmentsFor(habitId)))!;
    expect(commitments.single.repeatKind,
        defaultNewHabitCommitment.repeatKind);
    expect(commitments.single.isMeasurable, isFalse);
    expect(await tester.runAsync(() => db.select(db.todos).get()), isEmpty);
    final capture =
        (await tester.runAsync(() => db.captureDao.getCapture('c1')))!;
    expect(capture.clarifiedAt, isNotNull);

    // Backing out of the Habit lands on an Inbox without the capture.
    appRouter.pop();
    await _flush(tester);
    expect(find.byType(HabitDetailScreen), findsNothing);
    expect(find.text('Meditate'), findsNothing);
  }

  testWidgets('1-1: Make it a Habit clears the Inbox and opens the Habit',
      (tester) async {
    await open(tester);
    try {
      await journey(tester);
    } finally {
      await close(tester);
    }
  });

  testWidgets('n-m: the button is offered and works the same', (tester) async {
    await open(tester, mode: ClarifyMode.nToM);
    try {
      await journey(tester);
    } finally {
      await close(tester);
    }
  });
}
