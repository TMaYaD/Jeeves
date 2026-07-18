import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import '../test_helpers.dart';

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );

void main() {
  setUpAll(configureSqliteForTests);

  group('InboxNotifier.addCapture', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });
    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('addCapture stores an unclarified Capture', () async {
      await container.read(inboxNotifierProvider).addCapture('Buy milk');

      final items = await db.captureDao.watchInbox().first;
      expect(items.length, 1);
      expect(items.first.title, 'Buy milk');
      // NULL clarified_at is what puts it in the Inbox (ADR-0006).
      expect(items.first.clarifiedAt, isNull);
      expect(items.first.captureSource, 'manual');

      // Quick-add produces a Capture, never an Outcome: what the item should
      // become is exactly the question clarification answers later.
      expect(await db.select(db.todos).get(), isEmpty);
    });

    test('addCapture called twice yields two Inbox Captures', () async {
      final notifier = container.read(inboxNotifierProvider);
      await notifier.addCapture('Task one');
      await notifier.addCapture('Task two');

      final items = await db.captureDao.watchInbox().first;
      expect(items.length, 2);
      expect(items.every((c) => c.clarifiedAt == null), isTrue);
    });

    test('addCapture rejects a blank title', () async {
      final notifier = container.read(inboxNotifierProvider);

      expect(() => notifier.addCapture('   '), throwsArgumentError);
      expect(await db.captureDao.watchInbox().first, isEmpty);
    });

    test('fresh database has no inbox items', () async {
      final items = await db.captureDao.watchInbox().first;
      expect(items, isEmpty);
    });
  });
}
