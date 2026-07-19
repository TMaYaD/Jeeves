import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/async_list.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// Stand-in for a real list watch, so the error tests exercise the state
/// Riverpod actually produces rather than a hand-built `AsyncError`.
final _rowsProvider = StreamProvider<List<String>>((ref) => const Stream.empty());

/// Bounded pumping, not `pumpAndSettle`. The error branch logs through
/// `debugPrint`, whose throttle timer keeps the binding from ever reaching a
/// quiet frame, so settling would hang rather than fail.
Future<void> _pumpBriefly(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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
        'emptyBuilder is rendered verbatim — AsyncList adds no wrapper',
        (tester) async {
      // Caller owns scrollability / physics / RefreshIndicator wiring when
      // they supply emptyBuilder. AsyncList must not impose a Scrollable.
      await tester.pumpWidget(
        _wrap(
          AsyncList<String>(
            asyncValue: const AsyncData<List<String>>(<String>[]),
            emptyIcon: Icons.inbox_outlined,
            emptyTitle: 'Nothing here yet',
            emptyBuilder: (_) => const Text('Bare empty'),
            dataBuilder: (_, _) => const SizedBox.shrink(),
          ),
        ),
      );

      expect(find.text('Bare empty'), findsOneWidget);
      // No Scrollable should be introduced by AsyncList itself.
      expect(find.byType(Scrollable), findsNothing);
    });

    testWidgets(
        'a real stream error arrives as loading-carrying-an-error and still '
        'renders the error, not a spinner', (tester) async {
      // The AsyncSubject case, mirrored for lists (#428). Riverpod 3
      // auto-retries a failed provider, so a stream error never surfaces as a
      // plain AsyncError — it surfaces as AsyncLoading *carrying* the error,
      // which `AsyncValue.when` hands to its loading branch. Every errored
      // list screen would render an indefinite spinner instead of the error.
      final controller = StreamController<List<String>>.broadcast();
      addTearDown(controller.close);
      late AsyncValue<List<String>> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowsProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              observed = ref.watch(_rowsProvider);
              return AsyncList<String>(
                asyncValue: observed,
                emptyIcon: Icons.inbox_outlined,
                emptyTitle: 'Nothing here yet',
                dataBuilder: (_, _) => const SizedBox.shrink(),
              );
            }),
          ),
        ),
      ));
      controller.addError(Exception('SecretInternalDetail'));
      // Bounded pumping: the error branch logs through `debugPrint`, whose
      // throttle timer keeps the binding from ever reaching a quiet frame.
      await _pumpBriefly(tester);

      // Pin the premise, so this fails loudly if Riverpod changes the shape
      // rather than silently reducing to a weaker assertion.
      expect(observed.hasError, isTrue);
      expect(observed.isLoading, isTrue);
      expect(observed.hasValue, isFalse);

      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a stale list survives a refresh rather than flashing a spinner',
        (tester) async {
      final controller = StreamController<List<String>>.broadcast();
      addTearDown(controller.close);
      late WidgetRef capturedRef;
      late AsyncValue<List<String>> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowsProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              capturedRef = ref;
              observed = ref.watch(_rowsProvider);
              return AsyncList<String>(
                asyncValue: observed,
                emptyIcon: Icons.inbox_outlined,
                emptyTitle: 'Nothing here yet',
                dataBuilder: (_, items) => Text('rows: ${items.length}'),
              );
            }),
          ),
        ),
      ));
      controller.add(<String>['a', 'b']);
      await _pumpBriefly(tester);
      capturedRef.invalidate(_rowsProvider);
      await _pumpBriefly(tester);

      // Pin the state the widget was actually handed, so this keeps exercising
      // the retained-value branch rather than passing because the refresh
      // resolved before the assertions ran.
      expect(observed.isLoading, isTrue);
      expect(observed.hasValue, isTrue);
      // The error branch's guard must not swallow a refresh that still holds
      // rows.
      expect(find.text('rows: 2'), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
    });

    testWidgets('an empty list that then errors shows the error, not "empty"',
        (tester) async {
      // The retained-value exemption is keyed on having rows to show. A watch
      // that delivered `[]` and then failed retains the empty list, so gating
      // the error branch on bare `hasValue` would render the empty state — the
      // widget would report "nothing to see" when the truth is that the read
      // failed, making an empty inbox indistinguishable from a broken one.
      final controller = StreamController<List<String>>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowsProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              return AsyncList<String>(
                asyncValue: ref.watch(_rowsProvider),
                emptyIcon: Icons.inbox_outlined,
                emptyTitle: 'Nothing here yet',
                dataBuilder: (_, items) => Text('rows: ${items.length}'),
              );
            }),
          ),
        ),
      ));
      controller.add(const <String>[]);
      await _pumpBriefly(tester);
      expect(find.text('Nothing here yet'), findsOneWidget);

      controller.addError(StateError('SecretInternalDetail'));
      await _pumpBriefly(tester);

      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.text('Nothing here yet'), findsNothing);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
    });

    testWidgets('a reload that started from an empty list shows a spinner',
        (tester) async {
      // The counterpart of the AsyncSubject case: a refresh retains the
      // previous value, so a reload begun from `[]` reports `hasValue` with an
      // empty list inside. Keyed on that flag alone the widget would render
      // "nothing here yet" while the read that would populate it is still in
      // flight — an empty inbox and a pending one look identical.
      final controller = StreamController<List<String>>.broadcast();
      addTearDown(controller.close);
      late WidgetRef capturedRef;
      late AsyncValue<List<String>> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowsProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              capturedRef = ref;
              observed = ref.watch(_rowsProvider);
              return AsyncList<String>(
                asyncValue: observed,
                emptyIcon: Icons.inbox_outlined,
                emptyTitle: 'Nothing here yet',
                dataBuilder: (_, items) => Text('rows: ${items.length}'),
              );
            }),
          ),
        ),
      ));
      controller.add(const <String>[]);
      await _pumpBriefly(tester);
      expect(find.text('Nothing here yet'), findsOneWidget);

      capturedRef.invalidate(_rowsProvider);
      await _pumpBriefly(tester);

      expect(observed.isLoading, isTrue);
      expect(observed.hasValue, isTrue,
          reason: 'the reload retains the empty list it already delivered');

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Nothing here yet'), findsNothing);
    });

    testWidgets('an error after rows have loaded keeps showing the rows',
        (tester) async {
      // The other half of the `hasError && !hasValue` boundary. A watch that
      // fails *after* delivering rows reports both an error and a retained
      // value; replacing the list the user is reading with an error panel
      // mid-retry would be worse than leaving the last known rows up.
      final controller = StreamController<List<String>>.broadcast();
      addTearDown(controller.close);
      late AsyncValue<List<String>> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowsProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              observed = ref.watch(_rowsProvider);
              return AsyncList<String>(
                asyncValue: observed,
                emptyIcon: Icons.inbox_outlined,
                emptyTitle: 'Nothing here yet',
                dataBuilder: (_, items) => Text('rows: ${items.length}'),
              );
            }),
          ),
        ),
      ));
      controller.add(<String>['a', 'b']);
      await _pumpBriefly(tester);
      controller.addError(Exception('SecretInternalDetail'));
      await _pumpBriefly(tester);

      expect(observed.hasError, isTrue);
      expect(observed.hasValue, isTrue,
          reason: 'the failed watch retains the rows it already delivered');

      expect(find.text('rows: 2'), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
    });
  });
}
