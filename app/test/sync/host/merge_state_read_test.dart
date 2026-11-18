/// What a read of **one** entity out of merge state costs and answers.
///
/// The projector reads every entity it materialises through
/// [CollectionView.readEntity], so the read runs once per local edit, once per
/// imported record and once per entity of a whole-store re-projection. It has to
/// be a read of that entity's rows: answered by reading the whole collection and
/// picking one entry out, its cost is the size of the collection, and a walk of
/// the collection costs the square of it.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/sync_database.dart';

const String _collection = 'todos';
final String _memberA = 'a' * 32;
final String _memberB = 'b' * 32;

void main() {
  late SyncDatabase sync;
  late CollectionView view;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    sync = SyncDatabase(NativeDatabase.memory());
    view = CollectionRegistry(sync).register(_collection);
  });

  tearDown(() => sync.close());

  Future<void> writeField(
    String entityId,
    String field,
    String valueJson, {
    int wallMs = 10,
    int counter = 0,
    String? memberIdHex,
    String collection = _collection,
  }) async {
    await sync.customStatement(
      'INSERT INTO reduced_fields (collection, entity_id, field, value_json) '
      'VALUES (?, ?, ?, ?)',
      [collection, entityId, field, valueJson],
    );
    await sync.customStatement(
      'INSERT INTO field_clocks '
      '(collection, entity_id, field, wall_ms, counter, member_id_hex) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [collection, entityId, field, wallMs, counter, memberIdHex ?? _memberA],
    );
  }

  Future<void> writeTombstone(
    String entityId, {
    required int wallMs,
    int counter = 0,
    String? memberIdHex,
  }) =>
      sync.customStatement(
        'INSERT INTO row_tombstones '
        '(collection, entity_id, wall_ms, counter, member_id_hex) '
        'VALUES (?, ?, ?, ?, ?)',
        [_collection, entityId, wallMs, counter, memberIdHex ?? _memberA],
      );

  test('one entity is read from its own rows, not out of the whole collection',
      () async {
    await writeField('wanted', 'title', '"Ring Alice back"');
    // A value on a *different* entity that no reader can decode. A read that
    // walks the whole collection to answer for `wanted` trips over it; a read of
    // `wanted`'s own rows never sees it.
    await writeField('unrelated', 'title', '{not json');

    expect(await view.readEntity('wanted'), {'title': 'Ring Alice back'});
  });

  test('it answers exactly what a read of the whole collection answers',
      () async {
    // Live, with two fields.
    await writeField('live', 'title', '"Live"');
    await writeField('live', 'notes', 'null');
    // Deleted: every field is at or below the tombstone.
    await writeField('deleted', 'title', '"Deleted"', wallMs: 10);
    await writeTombstone('deleted', wallMs: 20);
    // Revived: one field is newer than the tombstone, one is not.
    await writeField('revived', 'title', '"Old title"', wallMs: 10);
    await writeField('revived', 'notes', '"Written after the delete"', wallMs: 30);
    await writeTombstone('revived', wallMs: 20);
    // The tombstone comparison is the whole clock, not the wall time alone.
    await writeField('tie-counter', 'title', '"Counter wins"',
        wallMs: 20, counter: 1);
    await writeTombstone('tie-counter', wallMs: 20, counter: 0);
    await writeField('tie-member', 'title', '"Member wins"',
        wallMs: 20, memberIdHex: _memberB);
    await writeField('tie-member', 'notes', '"Same clock as the delete"',
        wallMs: 20, memberIdHex: _memberA);
    await writeTombstone('tie-member', wallMs: 20, memberIdHex: _memberA);
    // The same id in another collection is another entity.
    await writeField('live', 'title', '"A tag, not an Outcome"',
        collection: 'tags');

    final whole = await view.readAll();
    expect(whole.keys,
        unorderedEquals(['live', 'revived', 'tie-counter', 'tie-member']));
    for (final entityId in [
      'live',
      'deleted',
      'revived',
      'tie-counter',
      'tie-member',
      'never-written',
    ]) {
      expect(await view.readEntity(entityId), whole[entityId],
          reason: 'entity "$entityId"');
    }
    expect(await view.readEntity('live'), {'title': 'Live', 'notes': null});
    expect(await view.readEntity('revived'),
        {'notes': 'Written after the delete'});
    expect(await view.readEntity('deleted'), isNull);
  });
}
