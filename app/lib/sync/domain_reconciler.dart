/// Domain-level convergence *decisions*, taken after a projection batch commits.
///
/// [DomainProjector] materialises reduced state and authors nothing, which is what
/// makes it order-independent for free. But some convergence rules are decisions
/// rather than materialisations — which of two same-`(name, type)` Tag entities
/// survives, and where a junction pointing at a tombstoned one should go — and a
/// decision only one device took is not convergence. So these passes author real
/// ops, which means they cannot run inside the projector's un-captured
/// transaction. They run after it.
///
/// **Two passes, two independent detection queries** (ADR-0043):
///
/// 1. **Fold** — collapse each duplicate `(name, type)` group onto `MIN(id)`
///    ([TagDao.foldDuplicateTags]).
/// 2. **Rehome** — repoint junction rows whose `tag_id` has no row in `tags` at
///    all.
///
/// The second is not a tidy-up of the first; it recovers a state the first cannot
/// see. With `X < Y < Z`: device A folds `Z→Y` and asserts its junction on Y, then
/// goes offline before pushing. B and C, never having seen that, fold `Y→X`. When
/// A's ops finally arrive, the junction on Y is live under a *greater* HLC than the
/// tombstone of Y — and the group is now `COUNT = 1`, so no duplicate-based
/// trigger will ever look at it again. That is a silently-lost Tag assignment, not
/// a loud failure. The rehome pass's condition — "a junction references a tag that
/// is not there" — is **durable**: it survives the `COUNT = 1` state and re-fires
/// on every subsequent reconcile until tag state has converged, at which point it
/// finds nothing.
///
/// A junction whose dead tag's `(name, type)` is unrecoverable, or for which no
/// live tag holds that pair, is **left alone**: that is the ordinary dangling
/// reference the projector deliberately tolerates, and inventing a delete for it
/// would destroy data to tidy a read model.
library;

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import 'collection_codecs.dart';
import 'domain_projector.dart';
import 'reducer.dart';

class DomainReconciler {
  DomainReconciler({required this.registry, required this.domain});

  /// Reduced state, read for one thing only: the last-asserted `(name, type)` of
  /// a Tag entity whose row is gone. The pair is recoverable nowhere else, and the
  /// alternative — never tombstoning losers — leaves duplicates on screen for
  /// ever. It is a deliberately widened seam (a domain repair reading the sync
  /// substrate), reviewed as such rather than absorbed as a detail.
  final CollectionRegistry registry;

  final GtdDatabase domain;

  /// Run the convergence passes, if anything in [collections] could have created
  /// work for them.
  ///
  /// [collections] is the set [DomainProjector.project] returns — the collection
  /// groups whose rows actually changed.
  ///
  /// ## Never call this from [DomainProjector.project]
  ///
  /// The ops these passes author emit through `GtdDatabase.capturing` →
  /// `commitScope` → the capture seam → `SyncClient.capture` → `project`
  /// (`domain_op_capture.dart`), so a reconcile inside `project` re-enters itself.
  /// It is driven from the two *batch tails* instead. All four `project` call
  /// sites, and the verdict for each:
  ///
  /// | Call site | Reconcile? | Why |
  /// |---|---|---|
  /// | `sync_client.dart` — author path (`capture`) | **No** | The authoring device's own write went through [TagDao.findOrCreateTag], which cannot mint a local duplicate, so there is nothing to fold. And this is the recursion site. |
  /// | `sync_client.dart` — compaction (`captureCompaction`) | **No** | A compaction snapshot's self-apply is a provable no-op and refuses if it ever is not, so it changes no domain row and can create no duplicate. |
  /// | `sync_client.dart` — pull tail | **Yes** | The route by which a peer's Tag entity first reaches the domain store. |
  /// | `domain_rebuild.dart` — replay tail | **Yes** | The other such route, and the one that repairs a device rebuilt from its own log. |
  ///
  /// Both "yes" sites are outside any transaction, so the passes' own
  /// `GtdDatabase.capturing` scopes open cleanly and the projector's "authors
  /// nothing" invariant is untouched: the projector materialises, this decides.
  ///
  /// [force] runs the passes whatever [collections] says. The gate answers "could
  /// *this batch* have created work?", which is the wrong question after an
  /// attempt that threw: the work is already outstanding, and the batch that
  /// created it has long since gone by. Its one caller is the pull tail's retry
  /// (`SyncClient._reconcileProjected`).
  Future<void> reconcile(Set<String> collections, {bool force = false}) async {
    if (!force &&
        !collections.contains(tagsCollection) &&
        !collections.contains(todoTagsCollection) &&
        !collections.contains(captureTagsCollection)) {
      return;
    }
    await domain.tagDao.foldDuplicateTags();
    await rehomeDanglingTagLinks();
  }

  /// Repoint every junction row whose `tag_id` has no row in `tags`.
  ///
  /// The durable-condition pass. For each absent `tag_id`, the dead entity's
  /// last-asserted `(name, type)` comes from reduced state via
  /// [CollectionView.readEntityIncludingHidden] — the same escape hatch the
  /// projector uses to delete a tombstoned junction, and the only record of the
  /// pair once the row is gone. The live tag for that pair is `MIN(id)`, which is
  /// the survivor the fold picks, so the two passes cannot fight.
  ///
  /// The repair goes through the DAO so it **travels as ops**: a peer holding the
  /// same stranded junction has to converge too, not merely this device.
  Future<void> rehomeDanglingTagLinks() async {
    final dangling = await domain.customSelect(
      'SELECT DISTINCT tag_id FROM ('
      '  SELECT tag_id FROM todo_tags'
      '  UNION ALL'
      '  SELECT tag_id FROM capture_tags'
      ') WHERE tag_id NOT IN (SELECT id FROM tags)',
      readsFrom: {domain.todoTags, domain.captureTags, domain.tags},
    ).get();
    if (dangling.isEmpty) return;

    final tagsView = registry.register(tagsCollection);
    for (final row in dangling) {
      final deadTagId = row.read<String>('tag_id');
      final lastAsserted = await tagsView.readEntityIncludingHidden(deadTagId);
      final name = lastAsserted['name'];
      final type = lastAsserted['type'];
      // Unrecoverable: nothing on record carries the pair, which is the state a
      // rebuild from a pruned log leaves. Left as the dangling reference it is.
      if (name is! String || type is! String) continue;

      final live = await domain.customSelect(
        'SELECT id FROM tags WHERE name = ? AND type = ? ORDER BY id LIMIT 1',
        variables: [Variable<String>(name), Variable<String>(type)],
        readsFrom: {domain.tags},
      ).getSingleOrNull();
      // No live tag holds the pair — the user deleted it outright, or it has not
      // arrived yet. Either way there is nowhere honest to point.
      if (live == null) continue;
      final survivorId = live.read<String>('id');
      if (survivorId == deadTagId) continue;

      await domain.tagDao
          .repointTagReferences(from: deadTagId, to: survivorId);
    }
  }
}
