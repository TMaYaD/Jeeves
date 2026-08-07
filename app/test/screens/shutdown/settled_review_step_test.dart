/// Widget tests for the Evening Shutdown summary step (#694).
///
/// The step's job is to show *everything the user resolved today*, grouped by
/// how it was resolved — so the disposition step that follows only has to ask
/// about genuinely open work. Both providers are overridden with
/// `Stream.value(...)`, the documented shape for a StreamProvider backed by a
/// live Drift watch (docs/TESTING.md § Frontend).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/evening_shutdown_provider.dart';
import 'package:jeeves/screens/shutdown/steps/settled_review_step.dart';

import '../../test_helpers.dart';

Todo _todo(String id, String title) => Todo(
      id: id,
      title: title,
      createdAt: DateTime.now(),
      clarified: true,
      intent: 'next',
      userId: 'local',
    );

Widget _step(Map<SessionSettlement, List<Todo>> groups) => ProviderScope(
      overrides: [
        sessionSettlementGroupsProvider.overrideWith(
          (_) => Stream.value(groups),
        ),
        loggedMinutesByOutcomeProvider.overrideWith(
          (_) => Stream.value(const <String, int>{}),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SettledReviewStep()),
      ),
    );

void main() {
  setUpAll(configureSqliteForTests);

  testWidgets('renders one heading per non-empty group, in render order',
      (tester) async {
    await tester.pumpWidget(_step({
      SessionSettlement.done: [_todo('d', 'Shipped it')],
      SessionSettlement.next: [_todo('n', 'Half-drafted it')],
      SessionSettlement.waitingFor: [_todo('w', 'Asked Trixy')],
      SessionSettlement.someday: [_todo('s', 'Parked it')],
    }));
    await tester.pump();

    for (final title in [
      'Shipped it',
      'Half-drafted it',
      'Asked Trixy',
      'Parked it',
    ]) {
      expect(find.text(title), findsOneWidget);
    }

    // Every group is headed, and the headings run in the declared order.
    final headings = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where((s) => s.contains('(1)'))
        .toList();
    expect(headings, hasLength(4));
    expect(
      headings.indexWhere((h) => h.startsWith('COMPLETED')) <
          headings.indexWhere((h) => h.startsWith('MORE WORK')),
      isTrue,
    );
    expect(
      headings.indexWhere((h) => h.startsWith('MORE WORK')) <
          headings.indexWhere((h) => h.startsWith('WAITING')),
      isTrue,
    );
    expect(
      headings.indexWhere((h) => h.startsWith('WAITING')) <
          headings.indexWhere((h) => h.startsWith('DEFERRED')),
      isTrue,
    );
  });

  testWidgets('omits empty groups (#694 AC6)', (tester) async {
    await tester.pumpWidget(_step({
      SessionSettlement.next: [_todo('n', 'Half-drafted it')],
    }));
    await tester.pump();

    expect(find.textContaining('MORE WORK LATER'), findsOneWidget);
    expect(find.textContaining('COMPLETED TODAY'), findsNothing);
    expect(find.textContaining('WAITING ON SOMEONE'), findsNothing);
    expect(find.textContaining('DEFERRED TO SOMEDAY'), findsNothing);
  });

  testWidgets(
      'the re-planned group tells the user it carries over — that is what '
      'makes its Disposition implicit rather than silent', (tester) async {
    await tester.pumpWidget(_step({
      SessionSettlement.done: [_todo('d', 'Shipped it')],
      SessionSettlement.next: [_todo('n', 'Half-drafted it')],
    }));
    await tester.pump();

    expect(find.textContaining('carry over'), findsOneWidget);
  });

  testWidgets('the other groups make no carry-over claim', (tester) async {
    await tester.pumpWidget(_step({
      SessionSettlement.done: [_todo('d', 'Shipped it')],
      SessionSettlement.waitingFor: [_todo('w', 'Asked Trixy')],
      SessionSettlement.someday: [_todo('s', 'Parked it')],
    }));
    await tester.pump();

    expect(find.textContaining('carry over'), findsNothing);
  });

  testWidgets('the empty state shows when nothing settled', (tester) async {
    await tester.pumpWidget(_step(const {}));
    await tester.pump();

    expect(find.textContaining('Nothing resolved yet today'), findsOneWidget);
  });

  testWidgets(
      'the Settled count spans every group; Done counts Completion only',
      (tester) async {
    await tester.pumpWidget(_step({
      SessionSettlement.done: [_todo('d', 'Shipped it')],
      SessionSettlement.next: [
        _todo('n1', 'Half-drafted it'),
        _todo('n2', 'Started the other'),
      ],
    }));
    await tester.pump();

    expect(find.text('SETTLED'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
