/// The initial-upload transform as a pure function: field encoding, id
/// derivation, and ADR-0025's auto-resolve.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/initial_upload_plan.dart';
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();
const String _userId = 'account-user';
final String _preferencesWorkspaceId = userPreferencesWorkspaceId(_userId);

String _id(String label) =>
    _uuid.v5(Namespace.url.value, 'jeeves-test://reseed-plan/$label');

String Function() _minter() {
  var minted = 0;
  return () => _id('minted/${++minted}');
}

/// A row source over a literal store, so the transform's inputs are visible in
/// the test rather than assembled by a fixture.
InitialUploadRowSource _rows(Map<String, List<Map<String, Object?>>> store) =>
    (table) async => store[table] ?? const [];

Future<InitialUploadPlan> _plan(
  Map<String, List<Map<String, Object?>>> store, {
  Map<String, InitialUploadTagRef> spineLabels = const {},
  String Function()? mintTagId,
}) =>
    buildInitialUploadPlan(
      readLegacyRows: _rows(store),
      userId: _userId,
      preferencesWorkspaceId: _preferencesWorkspaceId,
      mintTagId: mintTagId ?? _minter(),
      spineLabelTagsByName: spineLabels,
    );

void main() {
  group('encodeLegacyRow', () {
    test('stamps user_id rather than copying the legacy value', () {
      final encoded = encodeLegacyRow(
        collection: tagsCollection,
        row: {'name': 'Home', 'type': 'label', 'user_id': 'local'},
        userId: _userId,
      );
      // A row stranded under the placeholder user belongs to this account, and
      // the stamping is the declared exclusion that carries it there.
      expect(encoded.fields['user_id'], _userId);
      expect(encoded.unprojectable, isFalse);
    });

    test('truncates a dateTime column to the millisecond, never rounds', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.123999Z',
          'user_id': _userId,
        },
        userId: _userId,
      );
      expect(encoded.fields['created_at'], '2026-07-04T08:30:00.123Z');
    });

    test('normalises a non-UTC offset onto the canonical instant', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04 10:30:00.500+02:00',
          'user_id': _userId,
        },
        userId: _userId,
      );
      expect(encoded.fields['created_at'], '2026-07-04T08:30:00.500Z');
    });

    test('passes a TEXT timestamp column through byte for byte', () {
      // `todos.done_at` is declared TEXT, so the codec neither parses nor
      // normalises it — the truncation rule governs `dateTime` columns only.
      const raw = '2026-07-05T11:22:33.444999+00:00';
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.000Z',
          'done_at': raw,
          'user_id': _userId,
        },
        userId: _userId,
      );
      expect(encoded.fields['done_at'], raw);
    });

    test('reads an integer boolean column as a bool', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.000Z',
          'clarified': 1,
          'user_id': _userId,
        },
        userId: _userId,
      );
      expect(encoded.fields['clarified'], isTrue);
    });

    test('authors an explicit null for an absent optional column', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.000Z',
          'user_id': _userId,
        },
        userId: _userId,
      );
      // Present and null: the reseed asserts the emptiness of the column, so a
      // re-run cannot leave a stale value standing.
      expect(encoded.fields.containsKey('notes'), isTrue);
      expect(encoded.fields['notes'], isNull);
    });

    test('a NULL required column makes the row unprojectable', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'created_at': '2026-07-04T08:30:00.000Z',
          'user_id': _userId,
        },
        userId: _userId,
      );
      expect(encoded.unprojectable, isTrue);
      expect(encoded.fields.containsKey('title'), isFalse);
      expect(encoded.anomalies.single.kind, nullRequiredColumn);
      expect(encoded.anomalies.single.column, 'title');
    });

    test('a value the column kind refuses is omitted and named', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.000Z',
          'priority': 'not a number',
          'user_id': _userId,
        },
        userId: _userId,
      );
      // Optional, so the row still uploads — minus the column, loudly.
      expect(encoded.unprojectable, isFalse);
      expect(encoded.fields.containsKey('priority'), isFalse);
      expect(encoded.anomalies.single.kind, unencodableValue);
      expect(encoded.anomalies.single.raw, 'not a number');
    });

    test('an unparseable required timestamp makes the row unprojectable', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {'title': 'x', 'created_at': 'yesterday', 'user_id': _userId},
        userId: _userId,
      );
      expect(encoded.unprojectable, isTrue);
      expect(encoded.anomalies.single.column, 'created_at');
    });

    test('never emits todos.time_spent_minutes', () {
      final encoded = encodeLegacyRow(
        collection: todosCollection,
        row: {
          'title': 'x',
          'created_at': '2026-07-04T08:30:00.000Z',
          'user_id': _userId,
          'time_spent_minutes': 17,
        },
        userId: _userId,
      );
      // The dead cache: never on the wire (ADR-0030); the projector supplies the
      // column's declared default when it creates a row.
      expect(encoded.fields.containsKey('time_spent_minutes'), isFalse);
    });
  });

  group('initialUploadEntityIdFor', () {
    test('keeps the legacy id for an owned entity', () {
      expect(
        initialUploadEntityIdFor(
          collection: todosCollection,
          row: {'id': _id('todo/one')},
          preferencesWorkspaceId: _preferencesWorkspaceId,
        ),
        _id('todo/one'),
      );
    });

    test('derives a junction id from its pair', () {
      expect(
        initialUploadEntityIdFor(
          collection: todoTagsCollection,
          row: {
            'id': _id('junction/random'),
            'todo_id': _id('todo/one'),
            'tag_id': _id('tag/one'),
          },
          preferencesWorkspaceId: _preferencesWorkspaceId,
        ),
        todoTagIdFor(_id('todo/one'), _id('tag/one')),
      );
    });

    test('derives a preference id from its key and Workspace', () {
      expect(
        initialUploadEntityIdFor(
          collection: userPreferencesCollection,
          row: {'id': _id('preference/random'), 'key': 'clarify_mode'},
          preferencesWorkspaceId: _preferencesWorkspaceId,
        ),
        preferenceEntityId(_preferencesWorkspaceId, 'clarify_mode'),
      );
    });

    test('has no answer for a junction missing half its pair', () {
      expect(
        initialUploadEntityIdFor(
          collection: todoTagsCollection,
          row: {'id': _id('junction/orphan'), 'todo_id': _id('todo/one')},
          preferencesWorkspaceId: _preferencesWorkspaceId,
        ),
        isNull,
      );
    });
  });

  group('buildInitialUploadPlan', () {
    Map<String, List<Map<String, Object?>>> storeWith({
      required List<Map<String, Object?>> tags,
      required List<Map<String, Object?>> todoTags,
      List<Map<String, Object?>> todos = const [],
    }) =>
        {
          'tags': tags,
          'todos': todos,
          'todo_tags': todoTags,
        };

    Map<String, Object?> tagRow(String label, String name, String type,
            {String? color}) =>
        {
          'id': _id(label),
          'name': name,
          'type': type,
          'color': color,
          'user_id': _userId,
        };

    Map<String, Object?> todoRow(String label, String title) => {
          'id': _id(label),
          'title': title,
          'created_at': '2026-07-01T08:00:00.000Z',
          'user_id': _userId,
        };

    Map<String, Object?> membership(String rowLabel, String todoLabel,
            String tagLabel) =>
        {
          'id': _id(rowLabel),
          'todo_id': _id(todoLabel),
          'tag_id': _id(tagLabel),
          'user_id': _userId,
        };

    test('leaves a single-Area Outcome alone', () async {
      final plan = await _plan(storeWith(
        tags: [tagRow('tag/home', 'Home', areaTagType)],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [membership('junction/one', 'todo/one', 'tag/home')],
      ));
      expect(plan.resolutions, isEmpty);
      expect(plan.entitiesFor(todoTagsCollection), hasLength(1));
    });

    test('picks the primary Area by casefolded name, then id', () async {
      final plan = await _plan(storeWith(
        tags: [
          tagRow('tag/zeta', 'zeta', areaTagType),
          tagRow('tag/alpha', 'Alpha', areaTagType),
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/zeta', 'todo/one', 'tag/zeta'),
          membership('junction/alpha', 'todo/one', 'tag/alpha'),
        ],
      ));
      // Casefolded, so 'Alpha' beats 'zeta' rather than losing to it on the
      // uppercase-first byte order.
      expect(plan.resolutions.single.keptArea.name, 'Alpha');
    });

    test('breaks a same-name Area tie on the id, totally', () async {
      final first = _id('tag/home-a');
      final second = _id('tag/home-b');
      final lower = [first, second].reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
      final plan = await _plan(storeWith(
        tags: [
          {
            'id': second,
            'name': 'Home',
            'type': areaTagType,
            'user_id': _userId,
          },
          {
            'id': first,
            'name': 'Home',
            'type': areaTagType,
            'user_id': _userId,
          },
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          {
            'id': _id('junction/home-b'),
            'todo_id': _id('todo/one'),
            'tag_id': second,
            'user_id': _userId,
          },
          {
            'id': _id('junction/home-a'),
            'todo_id': _id('todo/one'),
            'tag_id': first,
            'user_id': _userId,
          },
        ],
      ));
      expect(plan.resolutions.single.keptArea.id, lower);
    });

    test('merges a surplus Area onto a legacy Label of the same name',
        () async {
      final plan = await _plan(storeWith(
        tags: [
          tagRow('tag/admin', 'admin', areaTagType),
          tagRow('tag/home-area', 'Home', areaTagType),
          tagRow('tag/home-label', 'Home', labelTagType, color: '#A855F7'),
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/admin', 'todo/one', 'tag/admin'),
          membership('junction/home', 'todo/one', 'tag/home-area'),
        ],
      ));
      final conversion = plan.resolutions.single.converted.single;
      expect(conversion.labelOrigin, labelOriginLegacyTag);
      expect(conversion.label.id, _id('tag/home-label'));
      expect(plan.labelsMinted, 0);
      // Nothing minted, so the Tag set is exactly the legacy one.
      expect(plan.entitiesFor(tagsCollection), hasLength(3));
    });

    test('resolves same-name legacy Labels by (casefolded name, id)', () async {
      final lower = _id('tag/label-a');
      final upper = _id('tag/label-b');
      final winner =
          [lower, upper].reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
      final plan = await _plan(storeWith(
        tags: [
          tagRow('tag/admin', 'admin', areaTagType),
          tagRow('tag/home-area', 'Home', areaTagType),
          {'id': upper, 'name': 'HOME', 'type': labelTagType, 'user_id': _userId},
          {'id': lower, 'name': 'home', 'type': labelTagType, 'user_id': _userId},
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/admin', 'todo/one', 'tag/admin'),
          membership('junction/home', 'todo/one', 'tag/home-area'),
        ],
      ));
      expect(plan.resolutions.single.converted.single.label.id, winner);
    });

    test('mints one Label per Area name however many Outcomes convert it',
        () async {
      final plan = await _plan(storeWith(
        tags: [
          tagRow('tag/admin', 'admin', areaTagType),
          tagRow('tag/work', 'Work', areaTagType, color: '#F97316'),
        ],
        todos: [todoRow('todo/one', 'One'), todoRow('todo/two', 'Two')],
        todoTags: [
          membership('junction/one-admin', 'todo/one', 'tag/admin'),
          membership('junction/one-work', 'todo/one', 'tag/work'),
          membership('junction/two-admin', 'todo/two', 'tag/admin'),
          membership('junction/two-work', 'todo/two', 'tag/work'),
        ],
      ));
      expect(plan.resolutions, hasLength(2));
      expect(plan.labelsMinted, 1);
      expect(plan.areaMembershipsConverted, 2);
      final minted = plan
          .entitiesFor(tagsCollection)
          .where((entity) => entity.legacyRowIds.isEmpty)
          .toList();
      expect(minted, hasLength(1));
      // The minted Label inherits the Area's name and colour, and is stamped with
      // the enrolled account like every other planned entity.
      expect(minted.single.fields['name'], 'Work');
      expect(minted.single.fields['color'], '#F97316');
      expect(minted.single.fields['type'], labelTagType);
      expect(minted.single.fields['user_id'], _userId);
    });

    test('merges onto a Label the spine already holds instead of minting',
        () async {
      final spineLabel = InitialUploadTagRef(id: _id('tag/spine-work'), name: 'Work');
      final plan = await _plan(
        storeWith(
          tags: [
            tagRow('tag/admin', 'admin', areaTagType),
            tagRow('tag/work', 'Work', areaTagType),
          ],
          todos: [todoRow('todo/one', 'One')],
          todoTags: [
            membership('junction/admin', 'todo/one', 'tag/admin'),
            membership('junction/work', 'todo/one', 'tag/work'),
          ],
        ),
        spineLabels: {'work': spineLabel},
      );
      final conversion = plan.resolutions.single.converted.single;
      expect(conversion.labelOrigin, labelOriginSpineTag);
      expect(conversion.label.id, spineLabel.id);
      expect(plan.labelsMinted, 0);
      // It has no legacy row, so the plan vouches for it rather than asserting it.
      expect(
        plan.endorsedEntityIdsByCollection[tagsCollection],
        {spineLabel.id},
      );
    });

    test('collapses a conversion onto a membership the Outcome already held',
        () async {
      final plan = await _plan(storeWith(
        tags: [
          tagRow('tag/admin', 'admin', areaTagType),
          tagRow('tag/home-area', 'Home', areaTagType),
          tagRow('tag/home-label', 'Home', labelTagType),
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/admin', 'todo/one', 'tag/admin'),
          membership('junction/home-area', 'todo/one', 'tag/home-area'),
          // Already carries the Label the Area converts to.
          membership('junction/home-label', 'todo/one', 'tag/home-label'),
        ],
      ));
      final conversion = plan.resolutions.single.converted.single;
      expect(conversion.collapsedOntoExistingMembership, isTrue);
      // Two memberships survive: the kept Area and the Label it already had.
      expect(plan.entitiesFor(todoTagsCollection), hasLength(2));
    });

    test('does not read a duplicate junction row as a second Area', () async {
      final plan = await _plan(storeWith(
        tags: [tagRow('tag/work', 'Work', areaTagType)],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/work-a', 'todo/one', 'tag/work'),
          membership('junction/work-b', 'todo/one', 'tag/work'),
        ],
      ));
      // One membership, one Area, nothing to resolve — and the duplicate row is
      // counted where a reviewer can see it.
      expect(plan.resolutions, isEmpty);
      expect(plan.entitiesFor(todoTagsCollection), hasLength(1));
      expect(
        plan.anomalies.where((one) => one.kind == collapsedDuplicateRow),
        hasLength(1),
      );
      expect(
        plan.entitiesFor(todoTagsCollection).single.legacyRowIds,
        hasLength(2),
      );
    });

    test('is a pure function of its inputs', () async {
      final store = storeWith(
        tags: [
          tagRow('tag/admin', 'admin', areaTagType),
          tagRow('tag/work', 'Work', areaTagType),
        ],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [
          membership('junction/admin', 'todo/one', 'tag/admin'),
          membership('junction/work', 'todo/one', 'tag/work'),
        ],
      );
      String describe(InitialUploadPlan plan) => [
            for (final entity in plan.entities)
              '${entity.collection}/${entity.entityId}/${entity.fields}',
            for (final resolution in plan.resolutions) '${resolution.toJson()}',
          ].join('|');

      // Same minter both times: the only non-deterministic input is the Tag id,
      // and it is injected precisely so the rest can be asserted as pure.
      expect(
        describe(await _plan(store, mintTagId: _minter())),
        describe(await _plan(store, mintTagId: _minter())),
      );
    });

    test('names a junction row with no derivable identity and excludes it',
        () async {
      final plan = await _plan(storeWith(
        tags: const [],
        todoTags: [
          {
            'id': _id('junction/orphan'),
            'todo_id': _id('todo/one'),
            'user_id': _userId,
          },
        ],
      ));
      expect(plan.entitiesFor(todoTagsCollection), isEmpty);
      expect(plan.anomalies.single.kind, missingIdentityColumns);
      expect(
        plan.excludedRowIdsByTable[todoTagsCollection],
        [_id('junction/orphan')],
      );
      expect(plan.excludedRowCount, 1);
    });

    test('authors preferences into the preferences Workspace', () async {
      final plan = await _plan({
        'user_preferences': [
          {
            'id': _id('preference/random'),
            'key': 'clarify_mode',
            'value': '"oneToOne"',
            'updated_at': '2026-07-01T07:00:00.000Z',
            'user_id': _userId,
          },
        ],
      });
      final entity = plan.entitiesFor(userPreferencesCollection).single;
      expect(entity.workspace, InitialUploadWorkspace.preferences);
      expect(
        entity.entityId,
        preferenceEntityId(_preferencesWorkspaceId, 'clarify_mode'),
      );
      // ADR-0033's key, plus the codec's required columns — which
      // `PreferencesStore.set` does not write, and the reseed must.
      expect(entity.fields['key'], 'clarify_mode');
      expect(entity.fields['user_id'], _userId);
      expect(entity.fields['updated_at'], '2026-07-01T07:00:00.000Z');
    });

    test('walks the collections parents-first', () async {
      final plan = await _plan(storeWith(
        tags: [tagRow('tag/home', 'Home', areaTagType)],
        todos: [todoRow('todo/one', 'One')],
        todoTags: [membership('junction/one', 'todo/one', 'tag/home')],
      ));
      final order = [
        for (final entity in plan.entities) entity.collection,
      ];
      expect(order.indexOf(tagsCollection), lessThan(order.indexOf(todosCollection)));
      expect(
        order.indexOf(todosCollection),
        lessThan(order.indexOf(todoTagsCollection)),
      );
    });
  });
}
