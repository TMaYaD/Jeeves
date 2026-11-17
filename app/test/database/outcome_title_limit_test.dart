/// The Outcome title's length limit is a limit the store keeps.
///
/// The number lives in two places: the column declaration, which drift turns
/// into an insert-time check, and [Todos.maxTitleLength], which the vault
/// reads before it carries a title. Drift reads the column's limit out of the
/// source as an **integer literal** — a constant reference reads as "no limit",
/// the check is dropped from the generated code without a word, and the store
/// then accepts a title of any length.
///
/// So this test writes the length the constant names and asks the store to
/// refuse it. If the two numbers ever disagree, it fails here, with a plain
/// message, rather than three files away in an import suite.
library;

import 'package:drift/drift.dart' show InvalidDataException;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  GtdDatabase openStore() {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  test('a title at the limit is kept', () async {
    final db = openStore();

    await db.into(db.todos).insert(
      TodosCompanion.insert(
        title: 'x' * Todos.maxTitleLength,
        createdAt: DateTime.now(),
        userId: 'u1',
      ),
    );

    expect(await db.select(db.todos).get(), hasLength(1));
  });

  test('a title over the limit is refused', () async {
    final db = openStore();

    await expectLater(
      db.into(db.todos).insert(
        TodosCompanion.insert(
          title: 'x' * (Todos.maxTitleLength + 1),
          createdAt: DateTime.now(),
          userId: 'u1',
        ),
      ),
      throwsA(isA<InvalidDataException>()),
    );
  });
}
