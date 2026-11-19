/// Widget test for [ImportScreen]'s title-bar chrome (#458) and its summary
/// card.
///
/// The screen's own import flow (file pick, parse, summary) is covered by
/// `nirvana_local_import_test.dart` / `nirvana_parser_test.dart` against the
/// import logic directly; this file pins the shared-bar contract and the
/// summary card's layout.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/import_provider.dart';
import 'package:jeeves/screens/import_screen.dart';

/// A notifier whose state is a finished import, so the summary card is on
/// screen without an import being run.
class _FinishedImportNotifier extends ImportNotifier {
  _FinishedImportNotifier(this.result);

  final ImportResult result;

  @override
  ImportState build() => ImportState(result: result);
}

void main() {
  group('ImportScreen', () {
    testWidgets('pins the global capture action in the bar (#458)',
        (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: ImportScreen()),
        ),
      );
      await tester.pump();

      // Direct find.byKey: the pinned slot never overflows.
      expect(find.byKey(const Key('capture_action')), findsOneWidget);
    });

    testWidgets('the summary heading fits a narrow screen', (tester) async {
      // A phone in portrait, and a heading long enough to need two lines:
      // "Import finished with 1000 records left out" does not fit beside
      // the icon on a narrow screen. It has to wrap, not overflow. The
      // viewport is tall enough for the summary card to be laid out — the
      // screen is a lazy list, and a card below the fold is not a card.
      tester.view.physicalSize = const Size(320, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final result = ImportResult(
        importedCount: 0,
        skippedCount: 0,
        projectTagsCreated: 0,
        failedRecords: [
          for (var i = 0; i < 1000; i++)
            ImportFailure(record: 'todos/$i', reason: 'the store refused it'),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            importNotifierProvider
                .overrideWith(() => _FinishedImportNotifier(result)),
          ],
          child: const MaterialApp(home: ImportScreen()),
        ),
      );
      await tester.pump();

      // The heading is on screen, and it did not overflow: an overflow is
      // reported as an error by the test framework, so reaching the end of
      // this test without one is the assertion.
      expect(find.textContaining('Import finished with'), findsOneWidget);
    });
  });
}
