import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';

/// Singleton [GtdDatabase] kept alive for the app lifetime.
///
/// Override with [GtdDatabase.forTesting] in tests.
final databaseProvider = Provider<GtdDatabase>((ref) {
  final db = GtdDatabase();
  ref.onDispose(db.close);
  return db;
});
