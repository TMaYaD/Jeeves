/// Drift table declarations for the local GTD database.
///
/// These mirror the backend PostgreSQL schema so Electric SQL can replicate
/// rows bidirectionally without column-name mismatches.
library;

import 'package:drift/drift.dart';

// ---------------------------------------------------------------------------
// todos
// ---------------------------------------------------------------------------

class Todos extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  IntColumn get priority => integer().nullable()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// GTD state: inbox | next_action | waiting_for | scheduled | someday_maybe | done
  TextColumn get state => text().withDefault(const Constant('inbox'))();

  /// Estimated effort in minutes (nullable).
  IntColumn get timeEstimate => integer().nullable()();

  /// Energy required: low | medium | high (nullable).
  TextColumn get energyLevel => text().nullable()();

  /// How this todo entered the inbox: manual | share_sheet | voice | ai_parse (nullable).
  TextColumn get captureSource => text().nullable()();

  TextColumn get locationId => text().nullable()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// tags
// ---------------------------------------------------------------------------

class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().withLength(max: 100)();
  TextColumn get color => text().nullable()();

  /// GTD discriminator: context | project | area | label
  TextColumn get type => text().withDefault(const Constant('context'))();

  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// todo_tags  (junction)
// ---------------------------------------------------------------------------

class TodoTags extends Table {
  TextColumn get todoId => text().references(Todos, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  @override
  Set<Column<Object>> get primaryKey => {todoId, tagId};
}
