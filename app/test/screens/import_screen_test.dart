/// Widget test for [ImportScreen]'s title-bar chrome (#458).
///
/// The screen's own import flow (file pick, parse, summary) is covered by
/// `nirvana_local_import_test.dart` / `nirvana_parser_test.dart` against the
/// import logic directly; this file only pins the shared-bar contract.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/screens/import_screen.dart';

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
  });
}
