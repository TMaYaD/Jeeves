/// A projector is refused a chunk size it could never finish with.
///
/// `DomainProjector.project` walks its entities `chunkEntityCount` at a time.
/// With zero the walk never gets past its first entity — it opens one empty
/// transaction after another, for good — and a negative count asks for a range
/// that does not exist. Both are refused where the projector is built, so the
/// mistake surfaces at the call that made it and not as a store that never
/// finishes re-projecting.
@TestOn('!browser')
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late SyncDatabase sync;
  late GtdDatabase domain;

  setUp(() {
    sync = SyncDatabase(NativeDatabase.memory());
    domain = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await domain.close();
    await sync.close();
  });

  DomainProjector projectorWithChunkOf(int chunkEntityCount) => DomainProjector(
        registry: CollectionRegistry(sync),
        domain: domain,
        chunkEntityCount: chunkEntityCount,
      );

  for (final chunkEntityCount in [0, -1]) {
    test('a chunk of $chunkEntityCount entities is refused', () {
      expect(
        () => projectorWithChunkOf(chunkEntityCount),
        throwsA(
          isA<ArgumentError>()
              .having((error) => error.name, 'name', 'chunkEntityCount'),
        ),
      );
    });
  }

  test('a chunk of one entity is accepted', () {
    expect(projectorWithChunkOf(1).chunkEntityCount, 1);
  });
}
