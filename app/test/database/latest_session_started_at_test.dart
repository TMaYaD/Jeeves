import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  test(
    'latest start stream follows open and closed sessions, not insert order',
    () async {
      final db = GtdDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final starts = StreamIterator(
        db.focusSessionDao.watchLatestSessionStartedAt(),
      );
      addTearDown(starts.cancel);
      expect(await starts.moveNext(), isTrue);
      expect(starts.current, isNull);

      final latest = DateTime.utc(2026, 5, 20, 19);
      final first = await db.focusSessionDao.openSession(
        userId: 'user',
        taskIds: [],
        now: latest,
      );
      expect(await starts.moveNext(), isTrue);
      expect(starts.current, latest);
      await db.focusSessionDao.closeSession(sessionId: first);
      expect(await starts.moveNext(), isTrue);
      expect(starts.current, latest);

      await db.focusSessionDao.openSession(
        userId: 'user',
        taskIds: [],
        now: latest.subtract(const Duration(days: 1)),
      );
      expect(await starts.moveNext(), isTrue);
      expect(starts.current, latest);
    },
  );
}
