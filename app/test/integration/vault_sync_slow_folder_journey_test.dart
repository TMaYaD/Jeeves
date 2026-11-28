/// The vault's journey through the app's own route, against a slow folder.
///
/// The same journey as `vault_sync_journey_test.dart`, with every operation
/// on the folder taking real time: the folder is slow the way a busy machine
/// or a slow disk makes it. The journey must still settle — a wait that
/// counted rounds rather than seconds did not, and the journey failed at
/// random in CI.
///
/// **Its own file, and so its own process.** The vault's attachments and
/// their cleanups go through one queue per process, and a cleanup left over
/// from the journey before it blocks the next journey's attachment: two
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
    journey = await VaultJourney.open(
      folderDelay: vaultJourneySlowFolderDelay,
    );
  });

  tearDown(() async {
    await journey.close();
  });

  testWidgets('the journey settles when every folder operation is slow', (
    tester,
  ) async {
    await journey.run(tester);
  });
}
