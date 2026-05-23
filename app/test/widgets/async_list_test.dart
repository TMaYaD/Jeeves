import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/async_list.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('AsyncList', () {
    testWidgets('loading state renders a CircularProgressIndicator',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncLoading<List<String>>(),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('error state renders friendly text (no raw error exposed)',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: AsyncError<List<String>>(
              Exception('SecretInternalDetail'),
              StackTrace.empty,
            ),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(
        find.textContaining('Something went wrong'),
        findsOneWidget,
      );
    });

    testWidgets('empty state renders icon and per-callsite title',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.search_off,
            emptyTitle: 'No tasks match "foo"',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('No tasks match "foo"'), findsOneWidget);
    });

    testWidgets('empty state renders optional subtitle when provided',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            emptySubtitle: 'Capture something from the bar above',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(
        find.text('Capture something from the bar above'),
        findsOneWidget,
      );
    });

    testWidgets('subtitle is absent when not provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Nothing here yet'), findsOneWidget);
      // Only one Text widget under the empty state.
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('CTA renders when provided and is tappable', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            emptyCta: ElevatedButton(
              onPressed: () => tapped = true,
              child: const Text('Add task'),
            ),
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Add task'), findsOneWidget);
      await tester.tap(find.text('Add task'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('CTA is absent when not provided', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.byType(ElevatedButton), findsNothing);
    });

    testWidgets('data state calls dataBuilder with items', (tester) async {
      List<String>? receivedItems;
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(['a', 'b']),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, items) {
              receivedItems = items;
              return Column(
                children: [for (final item in items) Text(item)],
              );
            },
          ),
        ),
      );

      expect(receivedItems, ['a', 'b']);
      expect(find.text('a'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets(
        'data state does not render the empty state when list is non-empty',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(['x']),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            dataBuilder: (_, items) => Text(items.first),
          ),
        ),
      );

      expect(find.text('Nothing here yet'), findsNothing);
      expect(find.byIcon(Icons.inbox_outlined), findsNothing);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets('emptyBuilder fully overrides the empty state when provided',
        (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            emptyBuilder: (_) => const Text('Custom empty surface'),
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Custom empty surface'), findsOneWidget);
      // Standard empty title and icon must not also render.
      expect(find.text('Nothing here yet'), findsNothing);
      expect(find.byIcon(Icons.inbox_outlined), findsNothing);
    });

    testWidgets(
        'emptyIsScrollable wraps empty state inside a scroll view '
        '(enables enclosing pull-to-refresh)', (tester) async {
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            emptyIsScrollable: true,
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Nothing here yet'), findsOneWidget);
      // A Scrollable ancestor must exist so RefreshIndicator gestures resolve.
      expect(find.byType(Scrollable), findsWidgets);
    });
  });
}
