/// The Now timeline's extras carry each Plan entry's accepted batch and
/// declined suggestion (issue #407), read from the real store.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);

  test('the extras reflect an accepted entry and a declined entry', () async {
    final db = GtdDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final now = DateTime.utc(2026, 11, 16, 8);
    for (final id in ['a', 'b', 'c']) {
      await db.into(db.todos).insert(TodosCompanion(
            id: Value(id),
            title: Value(id),
            userId: const Value(_userId),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
    }
    final sessionId = await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['a', 'b', 'c']);
    await db.focusSessionDao.acceptBatch(
      sessionId: sessionId,
      batchId: 'batch-1',
      startByTaskId: {'a': DateTime.utc(2026, 11, 16, 10)},
    );
    await db.focusSessionDao.declineBatchSuggestion(
      sessionId: sessionId,
      taskIds: ['b'],
      declinedAt: now,
    );

    container.listen(activeSessionBatchStateProvider, (_, _) {});
    final state = await container.read(activeSessionBatchStateProvider.future);
    expect(state['a'], (batchId: 'batch-1', declined: false));
    expect(state['b'], (batchId: null, declined: true));
    expect(state.containsKey('c'), isFalse);
  });
}
