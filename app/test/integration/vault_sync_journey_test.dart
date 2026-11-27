/// The vault, through the app's own route.
///
/// Turn the vault on in Settings, create an Outcome in the app, find its page
/// in the folder, edit the page by hand, bring the app forward, and see the
/// edit on screen.
///
/// This file holds the ordinary journey — the folder as it is. The slow
/// journey, against a folder whose every operation takes real time, is in
/// `vault_sync_slow_folder_journey_test.dart`, and the body they share is in
/// `vault_sync_journey_harness.dart`.
///
/// **One journey per file, and so one per process.** The vault's attachments
/// and their cleanups go through one queue per process, and a cleanup left
/// over from a journey that is over blocks the next journey's attachment: two
/// journeys in one file made the second one fail at random.
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';

import '../test_helpers.dart';
import 'vault_sync_journey_harness.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late VaultJourney journey;

  // The world is opened in `setUp`, not in the test body: a widget-test body
  // runs under `FakeAsync`, which cannot advance real I/O, so the first
  // `await` on a store never returns and the test hangs (see
  // `docs/TESTING.md`).
  setUp(() async {
    journey = await VaultJourney.open();
  });

  tearDown(() async {
    await journey.close();
  });

  testWidgets('a page edited by hand reaches the app when it comes forward', (
    tester,
  ) async {
    await journey.run(tester);
  });
}
