/// Integration journey (issue #723, AC8): the planned queue is offered at the
/// post-sprint re-clarify surface, and choosing one promotes it to `current`.
///
/// Drives the real [ReclarifyPromptSheet] — the exact surface a Focus sprint's
/// **Done** floats — over a real [GtdDatabase], through the path the issue
/// walks: an Outcome with a current Action and two queued `planned` Actions →
/// the current Action is completed (what Done does) → **More to do…** opens the
/// next-action dialog → both planned Actions are offered → tap one → it becomes
/// `current`, the other stays `planned`, and the Outcome routes to Next.
///
/// The Done → sheet wiring itself is pinned in `active_focus_screen_test.dart`;
/// this test floats the sheet over a minimal host (the codebase pattern in
/// `session_settlement_journey_test.dart`) to drive the *verdict* taps without
/// the Focus screen's fragile post-verdict navigation tail.
///
/// This test cannot pass on `main`: before #723 the dialog opened as a bare
/// text field, so neither planned Action was ever rendered — the "both offered"
/// assertion fails there, and no tap could promote one.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/reclarify_prompt_sheet.dart';

import '../helpers/active_focus_harness.dart' show openFocusInMemory, focusUserId;
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('Re-clarify → promote a planned Action (journey)', () {
    late GtdDatabase db;

    setUp(() => db = openFocusInMemory());
    tearDown(() async => db.close());

    Future<Todo> seedOutcomeWithQueue() async {
      final now = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: const Value('o1'),
            title: const Value('Ship the thing'),
            clarified: const Value(true),
            intent: const Value('next'),
            userId: const Value(focusUserId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
      await seedCurrentAction(
        db,
        outcomeId: 'o1',
        text: 'do it',
        userId: focusUserId,
      );
      // Queue two planned Actions with an explicit earlier timestamp, so the
      // stamp they leave on the Outcome is the value a later promotion must be
      // proven to move *forward* (AC5). addPlannedAction appends at positions
      // 0 and 1, so the queue order is deterministic.
      final earlier =
          DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      await db.actionDao
          .addPlannedAction('o1', 'Draft the outline', now: earlier);
      await db.actionDao.addPlannedAction('o1', 'Send for review', now: earlier);
      return (await db.todoDao.getTodo('o1'))!;
    }

    Widget host(Todo todo) => ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => ReclarifyPromptSheet.show(context, todo),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets(
        'a completed sprint offers the planned queue on the re-clarify sheet, '
        'and promoting one makes it current while the other stays planned',
        (tester) async {
      final todo = await seedOutcomeWithQueue();
      final stampBefore = (await db.todoDao.getTodo('o1'))!.lastClarifiedAt;
      expect(stampBefore, isNotNull);

      // What the Focus sprint's Done does: complete the current Action, leaving
      // the Outcome Actionless with its two planned rows.
      await db.actionDao.completeCurrentAction('o1');
      expect(await db.actionDao.getCurrentAction('o1'), isNull);

      // Float the real re-clarify sheet, exactly as Done does.
      await tester.pumpWidget(host(todo));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // "More to do…" opens the next-action dialog, which now offers the queue.
      await tester.tap(find.text('More to do…'));
      await tester.pumpAndSettle();
      expect(find.text('Draft the outline'), findsOneWidget,
          reason: 'the planned queue is offered on the re-clarify surface');
      expect(find.text('Send for review'), findsOneWidget);

      // Promote the first planned Action.
      await tester.tap(find.text('Draft the outline'));
      await tester.pumpAndSettle();

      // The chosen row is now current; the other remains planned.
      final current = await db.actionDao.getCurrentAction('o1');
      expect(current?.actionText, 'Draft the outline');
      final planned = await db.actionDao.getPlannedActions('o1');
      expect(planned.map((a) => a.actionText), ['Send for review']);

      // The Outcome is routed to Next…
      final row = await db.todoDao.getTodo('o1');
      expect(row?.intent, 'next');
      // …and promotion stamped last_clarified_at strictly forward — a bare
      // non-null check would pass on the pre-promote stamp, so the move is the
      // assertion (AC5).
      expect(row!.lastClarifiedAt!.isAfter(stampBefore!), isTrue,
          reason: 'promotion is an explicit clarifying act (ADR-0004)');
    });
  });
}
