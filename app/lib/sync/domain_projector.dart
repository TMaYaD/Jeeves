/// Reduced state → domain read model.
///
/// Two stores per device, by design. The [SyncDatabase] stays the
/// collection-generic convergence substrate — it is what "byte-identical" is
/// measured over, and a device that has not shipped a feature still reduces its
/// peers' writes rather than losing them. The [GtdDatabase] stays the domain
/// read model, fed by this projector.
///
/// Projection hangs off the tail of the receive order, after apply: the reducer
/// reports the entities it touched, `SyncClient` accumulates them over a pull
/// batch, and this runs once per batch.
///
/// **Idempotent on reduced state.** Projection may correct the *author's* local
/// rows in exactly two enumerated cases:
///
/// 1. the widened `deleteOutcome` cascade — the junction rows and
///    `time_logs.action_id` the shipped local delete left to the server's
///    `ON DELETE CASCADE`, which the op log does not have; and
/// 2. the **derived-id realignment** — for the two collections whose domain key
///    is not their `id` column, the projector locates the row by that key and
///    rewrites `id` to the derivation: `focusSessionTaskIdFor(sessionId,
///    taskId)` for `focus_session_tasks`, and `preferenceEntityId(workspace,
///    key)` for `user_preferences`, whose DAO still mints a random `id`
///    locally. Every device converges on the same row identity regardless of
///    which one authored the create.
///
/// Nothing else: with the TEXT pass-through rule every other field round-trips
/// to the author's own value (down to the millisecond floor the `dateTime`
/// encoding pins).
///
/// **Dangling references are not enforced.** Out-of-causal-order arrival is
/// routine and a tombstoned parent is permanent, so the projector never checks
/// referential existence — a TimeLog outlives its hard-deleted Outcome and
/// renders as *elsewhere*, it does not vanish and does not raise.
library;

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import 'collection_codecs.dart';
import 'reducer.dart';

class DomainProjector {
  DomainProjector({required this.registry, required this.domain});

  final CollectionRegistry registry;
  final GtdDatabase domain;

  /// Project every entity in [affected] and fire the ADR-0010 view notifies for
  /// the collection groups that changed.
  Future<void> project(Iterable<AffectedEntity> affected) async {
    if (affected.isEmpty) return;
    final touched = <String>{};
    await domain.transaction(() async {
      for (final entity in affected) {
        final codec = collectionCodecs[entity.collection];
        // Reduction is collection-generic; projection is not. An op for a
        // collection this build does not know still reduces — it simply has no
        // typed row to become.
        if (codec == null) continue;
        final view = registry.register(entity.collection);
        final live = await view.readEntity(entity.entityId);
        final changed = live == null || live.isEmpty
            ? await _delete(codec, entity.entityId, view)
            : await _upsert(codec, entity.entityId, live);
        if (changed) touched.add(entity.collection);
      }
    });
    notify(touched);
  }

  /// Fire the self-notify helper for every collection group in [collections].
  ///
  /// ADR-0010: in production these tables are PowerSync views with INSTEAD OF
  /// triggers, so a direct write reports `changes() == 0` and Drift's own
  /// stream invalidation never fires. A projected row is only visible to a
  /// watching view once its group is notified — and, since no FTS index exists
  /// (`search_dao` is a read-only query over the live tables), that notify is
  /// the whole requirement for search too.
  void notify(Set<String> collections) {
    if (collections.contains(todosCollection) ||
        collections.contains(todoTagsCollection)) {
      domain.notifyTodosViewWrite(
        includeTodoTags: collections.contains(todoTagsCollection),
      );
    }
    if (collections.contains(actionsCollection)) {
      domain.notifyActionsViewWrite();
    }
    if (collections.contains(timeLogsCollection)) {
      domain.notifyTimeLogsViewWrite();
    }
    if (collections.contains(tagsCollection)) {
      domain.notifyTagsViewWrite();
    }
    if (collections.contains(capturesCollection) ||
        collections.contains(captureOutcomesCollection) ||
        collections.contains(captureTagsCollection)) {
      domain.notifyCapturesViewWrite();
    }
    if (collections.contains(focusSessionsCollection) ||
        collections.contains(focusSessionTasksCollection) ||
        collections.contains(focusSessionDispositionsCollection)) {
      domain.notifyFocusSessionsViewWrite();
    }
    if (collections.contains('user_preferences')) {
      domain.notifyUserPreferencesViewWrite();
    }
  }

  Future<bool> _upsert(
    CollectionCodec codec,
    String entityId,
    Map<String, Object?> live,
  ) async {
    for (final required in codec.requiredColumns) {
      // Held back, not errored: reduced state converges, so the row lands on a
      // later pass once its remaining fields arrive.
      if (!live.containsKey(required)) return false;
    }
    final values = <String, Variable<Object>>{'id': Variable<String>(entityId)};
    for (final entry in codec.columns.entries) {
      if (!live.containsKey(entry.key)) continue;
      values[entry.key] = _bind(entry.value, live[entry.key]);
    }
    final identity = _identity(codec, entityId, live);
    if (identity == null) return false;

    final existing = await domain.customSelect(
      'SELECT 1 FROM "${codec.table}" WHERE ${identity.sql} LIMIT 1',
      variables: identity.variables,
    ).getSingleOrNull();

    if (existing == null) {
      final columns = values.keys.map((c) => '"$c"').join(', ');
      final placeholders = List.filled(values.length, '?').join(', ');
      await domain.customInsert(
        'INSERT INTO "${codec.table}" ($columns) VALUES ($placeholders)',
        variables: values.values.toList(),
      );
      return true;
    }
    // The identity columns are already what they are; `id` is set too, which is
    // the `focus_session_tasks` realignment (and a no-op everywhere else).
    final assignments = <String>[];
    final bound = <Variable<Object>>[];
    for (final entry in values.entries) {
      if (codec.identityColumns.contains(entry.key)) continue;
      assignments.add('"${entry.key}" = ?');
      bound.add(entry.value);
    }
    if (assignments.isEmpty) return true;
    await domain.customUpdate(
      'UPDATE "${codec.table}" SET ${assignments.join(', ')} '
      'WHERE ${identity.sql}',
      variables: [...bound, ...identity.variables],
    );
    return true;
  }

  Future<bool> _delete(
    CollectionCodec codec,
    String entityId,
    CollectionView view,
  ) async {
    // Nothing in the reduced store is deleted by a tombstone, so the entity's
    // last asserted fields are still on record — which is how a junction, whose
    // identity is its pair rather than its id, can still be located.
    final hidden = await view.readEntityIncludingHidden(entityId);
    final identity = _identity(codec, entityId, hidden);
    if (identity == null) return false;
    await domain.customUpdate(
      'DELETE FROM "${codec.table}" WHERE ${identity.sql}',
      variables: identity.variables,
    );
    return true;
  }

  ({String sql, List<Variable<Object>> variables})? _identity(
    CollectionCodec codec,
    String entityId,
    Map<String, Object?> fields,
  ) {
    if (codec.identifiedById) {
      return (sql: '"id" = ?', variables: [Variable<String>(entityId)]);
    }
    final clauses = <String>[];
    final variables = <Variable<Object>>[];
    for (final column in codec.identityColumns) {
      final value = fields[column];
      if (value is! String) return null;
      clauses.add('"$column" = ?');
      variables.add(Variable<String>(value));
    }
    return (sql: clauses.join(' AND '), variables: variables);
  }

  static Variable<Object> _bind(FieldKind kind, Object? value) =>
      switch (kind) {
        FieldKind.text => Variable<String>(value is String ? value : null),
        FieldKind.integer => Variable<int>(value is num ? value.toInt() : null),
        FieldKind.boolean => Variable<int>(
            value == null ? null : (value == true || value == 1 ? 1 : 0),
          ),
        FieldKind.instant => Variable<DateTime>(decodeInstant(value)),
      };
}
