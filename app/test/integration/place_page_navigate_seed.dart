/// Seeding for the errand hand-off journey (issue #60).
library;

import 'package:drift/drift.dart' show Value;

import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// A named Place at a point, with a default radius. Returns its id.
Future<String> seedPlace(
  GtdDatabase db,
  String name,
  double latitudeDegrees,
  double longitudeDegrees,
) async =>
    (await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    ))!;

/// An Outcome titled "Outcome [id]" whose current action is at [placeId].
Future<void> seedOutcomeAt(GtdDatabase db, String id, String placeId) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $id', userId: _userId);
  final action = (await db.actionDao.getCurrentAction(id))!.id;
  await db.actionDao.setNamedPlace(action, placeId);
}
