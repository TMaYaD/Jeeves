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
/// **Four passes, four independent detection queries** (ADR-0043):
///
/// 1. **Retype** — give the retired `'label'` Tag type the one value Labels
///    have now ([TagDao.retypeRetiredLabelTags]).
/// 2. **Fold** — collapse each duplicate `(name, type)` group onto `MIN(id)`
///    ([TagDao.foldDuplicateTags]).
/// 3. **Rehome** — repoint junction rows whose `tag_id` has no row in `tags` at
///    all.
/// 4. **One Project** — when an Outcome holds links to more than one Project
///    ([resolveMultipleProjects]), keep the most recently asserted and unassign
///    the rest.
///
/// **The retype runs before the fold, and the order is load-bearing.** A Tag
/// the sync cutover minted as `'label'` and a Label the user made as
/// `'context'` are two different `(name, type)` pairs, so the fold cannot see
/// them as one group. The retype turns the first into the second, and only then
/// has the fold a duplicate group to collapse — and the fold is what merges the
/// two Labels onto one row without losing a link. The other order would leave
/// the pair standing until a later reconcile.
///
/// The rehome pass is not a tidy-up of the fold; it recovers a state the fold
/// cannot see. With `X < Y < Z`: device A folds `Z→Y` and asserts its junction on Y, then
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

import '../database/daos/tag_dao.dart' show todoTagIdFor;
import '../database/gtd_database.dart';
import '../database/tables.dart' show labelTagType, retiredLabelTagType;
import 'collection_codecs.dart';
import 'domain_projector.dart';
import 'host/merge_state.dart';

class DomainReconciler {
  DomainReconciler({required this.registry, required this.domain});

  /// Reduced state, read for two things: the last-asserted `(name, type)` of a
  /// Tag entity whose row is gone (recoverable nowhere else; without it
  /// duplicates stay on screen for ever), and the clock of each `todo_tags` link
  /// (to pick the most recently assigned Project link as the survivor). It is a
  /// deliberately widened seam (a domain repair reading the sync substrate),
  /// reviewed as such rather than absorbed as a detail.
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
    await domain.tagDao.retypeRetiredLabelTags();
    await domain.tagDao.foldDuplicateTags();
    await rehomeDanglingTagLinks();
    await resolveMultipleProjects();
  }

  /// Leave each Outcome with one Project: the link with the greatest clock wins
  /// (ties go to the smaller tag id), and every other link is unassigned through
  /// [TagDao.unassignTag] so the tombstone travels to peers.
  ///
  /// Each link is its own sync entity, so two devices assigning different Projects
  /// author entities last-write-wins never compares; the writer's single-Project
  /// rule can only remove links its own device can see. The winner is not
  /// re-asserted: that would stamp it "now" and beat a genuinely later assignment
  /// from a device still offline. An Outcome with a link that has no clock on
  /// record is left alone — a local write not yet in merge state — and retried on
  /// the next reconcile.
  Future<void> resolveMultipleProjects() async {
    final contested = await domain.tagDao.outcomesWithMultipleProjects();
    if (contested.isEmpty) return;

    final linksView = registry.register(todoTagsCollection);
    for (final entry in contested.entries) {
      final todoId = entry.key;
      final clocks = <String,
          ({int wallMs, int counter, String memberIdHex})>{};
      for (final tagId in entry.value) {
        final clock =
            await linksView.readLatestClock(todoTagIdFor(todoId, tagId));
        if (clock != null) clocks[tagId] = clock;
      }
      if (clocks.length != entry.value.length) continue;

      int compare(String x, String y) {
        final cx = clocks[x]!;
        final cy = clocks[y]!;
        final byClock = cx.wallMs != cy.wallMs
            ? cx.wallMs.compareTo(cy.wallMs)
            : cx.counter != cy.counter
                ? cx.counter.compareTo(cy.counter)
                : cx.memberIdHex.compareTo(cy.memberIdHex);
        // Greater clock wins; on an exact tie the smaller tag id does.
        return byClock != 0 ? byClock : y.compareTo(x);
      }

      final ranked = [...entry.value]..sort(compare);
      final winner = ranked.last;
      await domain.capturing(() async {
        for (final tagId in entry.value) {
          if (tagId == winner) continue;
          await domain.tagDao.unassignTag(todoId, tagId);
        }
        domain.notifyTodosViewWrite(includeTodoTags: true);
      });
    }
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
      '  UNION ALL'
      '  SELECT tag_id FROM habit_tags'
      ') WHERE tag_id NOT IN (SELECT id FROM tags)',
      readsFrom: {
        domain.todoTags,
        domain.captureTags,
        domain.habitTags,
        domain.tags,
      },
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
      // A folded duplicate keeps the type it had when it was tombstoned, which
      // may be the retired one; its live survivor holds the Label value.
      final survivorType = type == retiredLabelTagType ? labelTagType : type;

      final live = await domain.customSelect(
        'SELECT id FROM tags WHERE name = ? AND type = ? ORDER BY id LIMIT 1',
        variables: [Variable<String>(name), Variable<String>(survivorType)],
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
