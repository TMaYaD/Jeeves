/// Unit tests for [AsyncSubject] — the four states a subject-bound surface can
/// be in, and the fact that three of them are told apart (#428).
///
/// The bug this pins: `value == null -> spinner` conflates "not answered yet"
/// with "answered, and the row is gone", so a deleted subject spins forever.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/async_subject.dart';
import 'package:jeeves/widgets/state_surfaces.dart';

Widget _harness(AsyncValue<String?> value, {Widget? missingCta}) {
  return MaterialApp(
    home: Scaffold(
      body: AsyncSubject<String>(
        asyncValue: value,
        dataBuilder: (_, subject) => Text(subject),
        missingTitle: 'This item is no longer here',
        missingCta: missingCta,
      ),
    ),
  );
}

void main() {
  testWidgets('loading renders the spinner and nothing else', (tester) async {
    await tester.pumpWidget(_harness(const AsyncValue.loading()));

    expect(find.byKey(LoadingSurface.surfaceKey), findsOneWidget);
    expect(find.byKey(ErrorSurface.surfaceKey), findsNothing);
    expect(find.text('This item is no longer here'), findsNothing);
  });

  testWidgets('data renders the subject', (tester) async {
    await tester.pumpWidget(_harness(const AsyncValue.data('Buy milk')));

    expect(find.text('Buy milk'), findsOneWidget);
    expect(find.byKey(LoadingSurface.surfaceKey), findsNothing);
  });

  testWidgets('an answered-but-absent row is the missing state, not a spinner',
      (tester) async {
    await tester.pumpWidget(_harness(const AsyncValue<String?>.data(null)));

    expect(find.text('This item is no longer here'), findsOneWidget);
    expect(find.byKey(LoadingSurface.surfaceKey), findsNothing);
    expect(find.byKey(ErrorSurface.surfaceKey), findsNothing);
  });

  testWidgets('an error is distinct from both loading and missing',
      (tester) async {
    await tester.pumpWidget(
      _harness(AsyncValue<String?>.error(Exception('boom'), StackTrace.empty)),
    );

    expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
    expect(find.byKey(LoadingSurface.surfaceKey), findsNothing);
    expect(find.text('This item is no longer here'), findsNothing);
    // Raw exception text is never user-facing copy.
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('an error after a null emission is an error, not an absence',
      (tester) async {
    // Riverpod keeps the previous value alongside the error, so `hasValue`
    // stays true here. An absence check that ran before the error check would
    // mislabel a failed query as "the row is gone" — the one case where the
    // two orderings differ.
    final feed = StreamController<String?>.broadcast();
    addTearDown(feed.close);
    final subject = StreamProvider<String?>((_) => feed.stream);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => AsyncSubject<String>(
              asyncValue: ref.watch(subject),
              dataBuilder: (_, s) => Text(s),
              missingTitle: 'This item is no longer here',
            ),
          ),
        ),
      ),
    ));

    feed.add(null);
    await tester.pumpAndSettle();
    expect(find.text('This item is no longer here'), findsOneWidget);

    feed.addError(Exception('boom'));
    await tester.pumpAndSettle();

    expect(find.byKey(ErrorSurface.surfaceKey), findsOneWidget);
    expect(find.text('This item is no longer here'), findsNothing);
  });

  testWidgets('the missing state renders the way out it was given',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(_harness(
      const AsyncValue<String?>.data(null),
      missingCta: Builder(
        builder: (context) => TextButton(
          onPressed: () => tapped = true,
          child: const Text('Back to Inbox'),
        ),
      ),
    ));

    await tester.tap(find.text('Back to Inbox'));
    expect(tapped, isTrue);
  });
}
