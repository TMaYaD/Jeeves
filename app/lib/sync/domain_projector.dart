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
///    is not their `id` column (`focus_session_tasks` and `user_preferences`),
///    the projector locates the row by that key and rewrites `id` to the op's
///    entity id. Both DAOs already mint the derivation locally
///    (`focusSessionTaskIdFor(sessionId, taskId)` and
///    `preferenceEntityId(workspace, key)`), as does the initial upload when it
///    authors a row that predates the id policy — so on this build the rewrite
///    is a no-op. It stays because it is what still realigns a row some *other*
///    build created at random, which is how every device converges on one row
///    identity regardless of which one authored the create.
///
/// Nothing else: with the TEXT pass-through rule every other field round-trips
/// to the author's own value (down to the millisecond floor the `dateTime`
/// encoding pins).
///
/// **Dangling references are not enforced.** Out-of-causal-order arrival is
/// routine and a tombstoned parent is permanent, so the projector never checks
/// referential existence — a TimeLog outlives its hard-deleted Outcome and
/// renders as *elsewhere*, it does not vanish and does not raise.
///
/// **The projector materialises; it never decides.** It authors nothing, which is
/// what makes it a pure function of reduced state and therefore order-independent
/// for free. Convergence *decisions* — which of two same-`(name, type)` Tag
/// entities survives, and where a junction on a tombstoned one should point —
/// have to reach peers, so they author ops and live in [DomainReconciler], which
/// runs after this has committed. That separation is also why `tags` carries no
/// `UNIQUE (name, type)`: the fold's own detection query has to be able to *see*
/// the duplicate, so the duplicate has to be representable (ADR-0043, #605).
library;

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import 'collection_codecs.dart';
import 'reducer.dart';

class DomainProjector {
  DomainProjector({required this.registry, required this.domain});

  final CollectionRegistry registry;
  final GtdDatabase domain;

  /// Project every entity in [affected], fire the view notifies for the
  /// collection groups that changed, and return those groups.
  ///
  /// The returned set is what a batch tail hands [DomainReconciler]: the trigger
  /// for a convergence pass is derived from the rows the projection actually
  /// wrote, not guessed at from the batch. It is the same set the notifies fire
  /// for, so a collection whose only entity was *held back* — a required column
  /// has not arrived yet — is absent from both.
  Future<Set<String>> project(Iterable<AffectedEntity> affected) async {
    final touched = <String>{};
    if (affected.isEmpty) return touched;
    // The projector materialises reduced state that is already on the op log,
    // so it must author nothing — the one sanctioned un-captured domain
    // transaction (GtdDatabase refuses a bare `transaction` outside a capturing
    // zone).
    await domain.uncapturedTransaction(() async {
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
    return touched;
  }

  /// Fire the self-notify helper for every collection group in [collections].
  ///
  /// these writes go through `customStatement` with no `updates:` set,
  /// so Drift has nothing to invalidate from, and a watcher that reads across a
  /// group only refreshes once the whole group is notified. Since no FTS index
  /// exists (`search_dao` is a read-only query over the live tables), the notify
  /// is the whole requirement for search too.
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
    if (collections.contains(userPreferencesCollection)) {
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
    // the derived-id realignment for `focus_session_tasks` and
    // `user_preferences` (and a no-op everywhere else).
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
    // ...except after a rebuild from the op log, which *does* clear them: an
    // entity whose every op became refused reduces to nothing, so a junction has
    // no pair left to be found by. Falling back to the sync row identifier is
    // exact rather than a guess — this projector sets `id` to the entity id on
    // every row it writes, including the two collections whose domain key is not
    // their `id` column.
    final identity =
        _identity(codec, entityId, hidden) ?? (hidden.isEmpty ? _byRowId(entityId) : null);
    if (identity == null) return false;
    await domain.customUpdate(
      'DELETE FROM "${codec.table}" WHERE ${identity.sql}',
      variables: identity.variables,
    );
    return true;
  }

  static ({String sql, List<Variable<Object>> variables}) _byRowId(String entityId) =>
      (sql: '"id" = ?', variables: [Variable<String>(entityId)]);

  ({String sql, List<Variable<Object>> variables})? _identity(
    CollectionCodec codec,
    String entityId,
    Map<String, Object?> fields,
  ) {
    if (codec.identifiedById) return _byRowId(entityId);
    final clauses = <String>[];
    final variables = <Variable<Object>>[];
    for (final column in codec.identityColumns) {
      final value = fields[column];
      if (value is! String) return null;
      clauses.add('"$column" = ?');
      variables.add(Variable<String>(value));
    }
    // A codec with no identity columns would join to an empty WHERE clause —
    // a syntax error on the SELECT and an unbounded DELETE. Fail closed rather
    // than emit either; the entity is held back like any unlocatable row.
    if (clauses.isEmpty) return null;
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
