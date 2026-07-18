/// Widget tests for [AsyncSubject] — the four states a subject-bound surface
/// can be in (#428).
///
/// The bug this widget exists to prevent is the three-way collapse: every
/// subject-bound surface used to render `value == null -> spinner`, which made
/// *loading*, *errored* and *gone* indistinguishable. The assertions here are
/// deliberately negative as well as positive — "the missing state renders a
/// panel" is worth little without "…and no spinner".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/async_subject.dart';

Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

/// Feeds the two "in-flight" states that cannot be constructed from the public
/// API — `AsyncLoading` carrying a previous error, and one carrying a previous
/// value. Driving a real provider is not just a workaround for
/// `copyWithPrevious` being `@internal`: it is the only way to assert that the
/// states this widget branches on are the ones Riverpod actually emits. Both
/// shapes are verified by the tests below rather than assumed.
final _rowProvider = StreamProvider.autoDispose<String?>((ref) {
  throw UnimplementedError('overridden per test');
});

Widget _subject(
  AsyncValue<String?> value, {
  Widget? missingCta,
  WidgetBuilder? missingBuilder,
  Widget Function(BuildContext, Widget)? chrome,
}) =>
    AsyncSubject<String>(
      asyncValue: value,
      missingIcon: Icons.search_off,
      missingTitle: 'This item no longer exists',
      missingSubtitle: 'It may have been deleted on another device.',
      missingCta: missingCta,
      missingBuilder: missingBuilder,
      chrome: chrome,
      dataBuilder: (_, subject) => Text('loaded: $subject'),
    );

void main() {
  group('AsyncSubject — the three non-data states are distinguishable', () {
    testWidgets('loading renders a spinner and no missing panel',
        (tester) async {
      await tester.pumpWidget(_wrap(_subject(const AsyncLoading<String?>())));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('This item no longer exists'), findsNothing);
      expect(find.textContaining('Something went wrong'), findsNothing);
    });

    testWidgets('error renders friendly copy — never the exception text',
        (tester) async {
      await tester.pumpWidget(_wrap(_subject(
        AsyncError<String?>(
          Exception('SecretInternalDetail'),
          StackTrace.empty,
        ),
      )));

      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('This item no longer exists'), findsNothing);
    });

    testWidgets(
        'a real stream error arrives as loading-carrying-an-error and still '
        'renders the error, not a spinner', (tester) async {
      final controller = StreamController<String?>.broadcast();
      addTearDown(controller.close);
      late AsyncValue<String?> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              observed = ref.watch(_rowProvider);
              return _subject(observed);
            }),
          ),
        ),
      ));
      controller.addError(Exception('SecretInternalDetail'));
      // Bounded pumping: the error branch logs through `debugPrint`, whose
      // throttle timer keeps the binding from ever reaching a quiet frame.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Pin the premise, so this test fails loudly if Riverpod ever changes
      // the shape rather than silently reducing to a weaker assertion:
      // an errored stream reports `isLoading` AND `hasError`, which is exactly
      // why `AsyncValue.when` cannot be used here — it would dispatch this to
      // the loading branch and hand the user another indefinite spinner.
      expect(observed.hasError, isTrue);
      expect(observed.isLoading, isTrue);
      expect(observed.hasValue, isFalse);

      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a stale value survives a refresh rather than flashing a spinner',
        (tester) async {
      final controller = StreamController<String?>.broadcast();
      addTearDown(controller.close);
      late WidgetRef capturedRef;
      late AsyncValue<String?> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              capturedRef = ref;
              observed = ref.watch(_rowProvider);
              return _subject(observed);
            }),
          ),
        ),
      ));
      controller.add('hi');
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      capturedRef.invalidate(_rowProvider);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Refreshing retains the previous value, so `hasValue` stays true even
      // though the provider reports loading — the `!hasValue` guard is what
      // keeps the last known row on screen instead of replacing it.
      expect(observed.isLoading, isTrue);
      expect(observed.hasValue, isTrue);

      expect(find.text('loaded: hi'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an error after the subject loaded keeps the last known row',
        (tester) async {
      // The other half of the `hasError && !hasValue` boundary: `hasError`
      // alone must not tip a surface that still holds its row into the error
      // panel. Dropping the row the user is editing because a retry failed
      // would be worse than showing it slightly stale.
      final controller = StreamController<String?>.broadcast();
      addTearDown(controller.close);
      late AsyncValue<String?> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              observed = ref.watch(_rowProvider);
              return _subject(observed);
            }),
          ),
        ),
      ));
      controller.add('hi');
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      controller.addError(Exception('SecretInternalDetail'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(observed.hasError, isTrue);
      expect(observed.hasValue, isTrue,
          reason: 'the failed watch retains the row it already delivered');

      expect(find.text('loaded: hi'), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsNothing);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
      expect(find.text('This item no longer exists'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'a null that then errors shows the error, not the missing panel',
        (tester) async {
      // The retained-value exemption is keyed on holding an actual row. A watch
      // that emitted `null` and then failed retains the null, so gating the
      // error branch on bare `hasValue` would render the *missing* panel: the
      // surface would claim the row was deleted when the read merely failed,
      // and offer an escape premised on that. Mirrors the empty-list case in
      // async_list_test.dart.
      final controller = StreamController<String?>.broadcast();
      addTearDown(controller.close);
      late AsyncValue<String?> observed;

      await tester.pumpWidget(ProviderScope(
        overrides: [_rowProvider.overrideWith((ref) => controller.stream)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              observed = ref.watch(_rowProvider);
              return _subject(observed);
            }),
          ),
        ),
      ));
      controller.add(null);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('This item no longer exists'), findsOneWidget);

      controller.addError(Exception('SecretInternalDetail'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(observed.hasError, isTrue);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.text('This item no longer exists'), findsNothing);
      expect(find.textContaining('SecretInternalDetail'), findsNothing);
    });

    testWidgets('AsyncData(null) renders the missing panel, NOT a spinner',
        (tester) async {
      await tester.pumpWidget(_wrap(_subject(const AsyncData<String?>(null))));

      expect(find.text('This item no longer exists'), findsOneWidget);
      expect(
        find.text('It may have been deleted on another device.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.search_off), findsOneWidget);
      // The whole point of #428: absent must not read as loading.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('AsyncData(value) renders the data surface', (tester) async {
      await tester.pumpWidget(_wrap(_subject(const AsyncData<String?>('hi'))));

      expect(find.text('loaded: hi'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('This item no longer exists'), findsNothing);
    });
  });

  group('AsyncSubject — the way out', () {
    testWidgets('missing state renders the CTA and fires it on tap',
        (tester) async {
      var escaped = 0;
      await tester.pumpWidget(_wrap(_subject(
        const AsyncData<String?>(null),
        missingCta: Builder(
          builder: (_) => FilledButton(
            onPressed: () => escaped++,
            child: const Text('Continue'),
          ),
        ),
      )));

      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(escaped, 1);
    });

    testWidgets('missingBuilder replaces the standard panel entirely',
        (tester) async {
      await tester.pumpWidget(_wrap(_subject(
        const AsyncData<String?>(null),
        missingBuilder: (_) => const Text('bounced'),
      )));

      expect(find.text('bounced'), findsOneWidget);
      expect(find.text('This item no longer exists'), findsNothing);
    });
  });

  group('AsyncSubject — chrome', () {
    testWidgets('wraps loading, error and missing but not data',
        (tester) async {
      Widget chrome(BuildContext context, Widget surface) => Column(
            children: [const Text('CHROME'), Expanded(child: surface)],
          );

      for (final state in <AsyncValue<String?>>[
        const AsyncLoading<String?>(),
        AsyncError<String?>(Exception('x'), StackTrace.empty),
        const AsyncData<String?>(null),
      ]) {
        await tester.pumpWidget(_wrap(_subject(state, chrome: chrome)));
        expect(find.text('CHROME'), findsOneWidget,
            reason: 'chrome must wrap $state');
      }

      await tester.pumpWidget(
        _wrap(_subject(const AsyncData<String?>('hi'), chrome: chrome)),
      );
      expect(find.text('CHROME'), findsNothing);
      expect(find.text('loaded: hi'), findsOneWidget);
    });
  });
}
