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

  group('InboxNotifier.addTodo', () {
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

    test('addTodo stores item visible via DAO', () async {
      await container.read(inboxNotifierProvider).addTodo('Buy milk');

      final items = await db.inboxDao.watchInbox('local').first;
      expect(items.length, 1);
      expect(items.first.title, 'Buy milk');
      expect(items.first.state, 'inbox');
      expect(items.first.captureSource, 'manual');
    });

    test('addTodo called twice yields two items', () async {
      final notifier = container.read(inboxNotifierProvider);
      await notifier.addTodo('Task one');
      await notifier.addTodo('Task two');

      final items = await db.inboxDao.watchInbox('local').first;
      expect(items.length, 2);
    });

    test('fresh database has no inbox items', () async {
      final items = await db.inboxDao.watchInbox('local').first;
      expect(items, isEmpty);
    });
  });
}
