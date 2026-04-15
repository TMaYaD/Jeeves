import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'inbox_provider.dart' show kLocalUserId;

export '../database/gtd_database.dart' show Todo;

/// Stream of next-action todos, excluding blocked tasks.
final nextActionsProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchNextActions(kLocalUserId);
});

/// Stream of waiting-for todos.
final waitingForProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchWaitingFor(kLocalUserId);
});

/// Stream of someday/maybe todos.
final somedayMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchSomedayMaybe(kLocalUserId);
});
