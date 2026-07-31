/// Two devices, one Tag name: the domain store converges rather than raising.
///
/// Tag ids are client-random UUIDv4 by protocol policy (`sync/ids.dart`), so two
/// devices that each create "Alice"/`person` offline fork into two *entities* by
/// design — and since People are `Tag(type='person')` (CONTEXT.md), every person
/// a user adds on two devices takes this path. Before #605 the projector's bare
/// `INSERT INTO tags` hit `UNIQUE (name, type)` and raised `SqliteException(2067)`
/// out of `SyncClient.pull()`, rolling back **every** entity in the batch and
/// leaving a permanent hole in the read model.
///
/// The convergence rule under test: the duplicate is representable, and the
/// `DomainReconciler` folds the group onto `MIN(id)` by authoring real ops, so
/// every peer converges rather than only the device that noticed. Nothing here is
/// stubbed — real DAOs, real crypto, real transport, real reduce and project
/// path — so a claim this file makes is a claim about production.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/domain_reconciler.dart';
import 'package:jeeves/sync/ids.dart' show jeevesWorkspaceNamespace;
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const String _userId = 'sim-user';

/// Entity ids are canonical lowercase UUIDs on the wire — `capture()` runs the
/// same codec a receiver does and refuses anything else — so fixture ids are
/// derived rather than hand-written.
String _id(String label) =>
    const Uuid().v5(jeevesWorkspaceNamespace, 'sim/$label');

/// Three derived ids in lexicographic order, which is the order `MIN(id)` ranks
/// them in.
///
/// Pinning the *expected winner* by construction rather than by a literal is what
/// keeps "the survivor is the minimum" a statement about the rule instead of about
/// whichever uuid the namespace happened to produce.
List<String> _idsInMinOrder(List<String> labels) =>
    [for (final label in labels) _id(label)]..sort();

void main() {
  setUpAll(configureSqliteForTests);

  /// Rows of [table] on every device, as full maps — the shape a cross-device
  /// equality assertion compares.
  Future<List<List<Map<String, Object?>>>> rowsOnEach(
    List<SimDevice> devices,
    String table, {
    String orderBy = 'id',
  }) async =>
      [
        for (final device in devices)
          await domainRows(device.domain, table, orderBy: orderBy),
      ];

  /// Assert every device in [devices] holds identical rows for [table].
  Future<List<Map<String, Object?>>> expectConverged(
    List<SimDevice> devices,
    String table, {
    String orderBy = 'id',
  }) async {
    final perDevice = await rowsOnEach(devices, table, orderBy: orderBy);
    for (var index = 1; index < perDevice.length; index++) {
      expect(perDevice[index], perDevice.first,
          reason: '$table diverged between ${devices.first.label} and '
              '${devices[index].label}');
    }
    return perDevice.first;
  }

  /// Assert the substrate agrees too, not only the read model: a projection that
  /// matched over a reduced state that did not would be a coincidence.
  Future<void> expectReducedStateAgrees(List<SimDevice> devices) async {
    final canonical = <String>[
      for (final device in devices) await canonicalReducedState(device.database),
    ];
    for (var index = 1; index < canonical.length; index++) {
      expect(canonical[index], canonical.first,
          reason: 'reduced state diverged between ${devices.first.label} and '
              '${devices[index].label}');
    }
  }

  /// Sync [order] repeatedly until nothing more moves.
  ///
  /// Three rounds rather than [SimWorkspace.syncAll]'s two, because the fold is a
  /// *write*: its ops are authored at the pull tail and therefore only leave the
  /// device on a later push. The explicit device order is what makes "both arrival
  /// orders" expressible.
  Future<void> settle(List<SimDevice> order, {int rounds = 3}) async {
    for (var round = 0; round < rounds; round++) {
      for (final device in order) {
        await device.syncIfOnline();
      }
    }
  }

  Future<String> outcomeOn(SimDevice device, String label) async {
    final id = _id(label);
    await device.domain.todoDao.insertOutcome(
      id: id,
      title: 'Outcome $label',
      userId: _userId,
      now: device.clock.asDateTime,
    );
    return id;
  }

  /// Create a tag with a **pinned** id through the ordinary DAO write path, so a
  /// test can say which id `MIN(id)` must pick.
  Future<void> tagWithId(
    SimDevice device,
    String tagId, {
    String name = 'Alice',
    String type = 'person',
  }) =>
      device.domain.tagDao.upsertTag(TagsCompanion(
        id: Value(tagId),
        name: Value(name),
        type: Value(type),
        color: const Value('#ff8800'),
        userId: const Value(_userId),
      ));

  Future<List<Map<String, Object?>>> personTags(SimDevice device) async =>
      domainRows(device.domain, 'tags')
          .then((rows) => rows.where((r) => r['type'] == 'person').toList());

  group('two devices, one Tag name', () {
    late SimWorkspace workspace;
    late SimDevice a;
    late SimDevice b;

    setUp(() async {
      workspace = await SimWorkspace.create();
      a = workspace.a;
      b = workspace.b;
      // Settle enrolment before the scenario, so the batch under test carries
      // only the scenario's own ops.
      await workspace.syncAll();
    });
    tearDown(() async => workspace.close());

    test(
        "a peer's duplicate (name, type) Tag converges, and the rest of its "
        'batch survives', () async {
      // AC-2: an unrelated Outcome rides in the *same* batch as the duplicate
      // Tag. Before #605 the projector's raise rolled the whole batch back, so
      // this Outcome is what proves the batch is no longer collateral damage.
      b.goOffline();
      final outcomeA = await outcomeOn(a, 'outcome-a');
      final unrelatedA = await outcomeOn(a, 'unrelated-a');
      final tagA =
          await a.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await a.domain.tagDao.assignTag(outcomeA, tagA, _userId);

      final outcomeB = await outcomeOn(b, 'outcome-b');
      final unrelatedB = await outcomeOn(b, 'unrelated-b');
      final tagB =
          await b.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await b.domain.tagDao.assignTag(outcomeB, tagB, _userId);

      // Two entities, by design (`sync/ids.dart`): random ids, same pair.
      expect(tagA, isNot(tagB));

      b.goOnline();
      // The assertion is that this does not throw. Before #605 it raised
      // SqliteException(2067) out of `pull()`.
      await settle([a, b]);

      // AC-1/AC-2: one Tag, the same one, on both devices.
      final tags = await expectConverged([a, b], 'tags');
      final alice = tags.where((row) => row['name'] == 'Alice').toList();
      expect(alice, hasLength(1), reason: 'the duplicate pair did not fold');
      final survivor = alice.single['id'];
      expect(survivor, [tagA, tagB].reduce((x, y) => x.compareTo(y) <= 0 ? x : y),
          reason: 'the survivor is MIN(id) over the group');

      // AC-3: neither device's assignment was lost, and both sit on the survivor.
      final junctions = await expectConverged([a, b], 'todo_tags');
      expect(
        junctions.map((row) => row['todo_id']).toSet(),
        {outcomeA, outcomeB},
      );
      expect(junctions.map((row) => row['tag_id']).toSet(), {survivor});

      // The rest of the batch: present on both, which it was not while the
      // projector raised.
      final outcomes = await expectConverged([a, b], 'todos');
      expect(
        outcomes.map((row) => row['id']).toSet(),
        {outcomeA, outcomeB, unrelatedA, unrelatedB},
      );

      await expectReducedStateAgrees([a, b]);
    });

    test('MIN(id) wins over reference count', () async {
      // The ranking this replaces — `ref_count DESC, id ASC` — is *device-local*:
      // two devices folding concurrently would pick different survivors, each
      // tombstone the other's, and kill both Tags. So the tag with FEWER
      // references must win when its id is smaller.
      final ids = _idsInMinOrder(['tag-small', 'tag-large']);
      final smaller = ids.first;
      final larger = ids.last;

      b.goOffline();
      // A holds the *heavily referenced* tag, under the LARGER id.
      await tagWithId(a, larger);
      for (final label in ['ref-1', 'ref-2', 'ref-3']) {
        final outcome = await outcomeOn(a, label);
        await a.domain.tagDao.assignTag(outcome, larger, _userId);
      }
      // B holds one reference, under the SMALLER id.
      await tagWithId(b, smaller);
      final loneOutcome = await outcomeOn(b, 'ref-lone');
      await b.domain.tagDao.assignTag(loneOutcome, smaller, _userId);

      b.goOnline();
      await settle([a, b]);

      final alice = await personTags(a);
      expect(alice, hasLength(1));
      expect(alice.single['id'], smaller,
          reason: 'MIN(id) must win; a ref-count ranking would pick $larger');
      await expectConverged([a, b], 'tags');

      // Every one of the four assignments landed on the survivor.
      final junctions = await expectConverged([a, b], 'todo_tags');
      expect(junctions, hasLength(4));
      expect(junctions.map((row) => row['tag_id']).toSet(), {smaller});
    });

    test('a tag hint on the losing tag is rehomed onto the survivor', () async {
      // `capture_tags` is the junction `merge`/`dedupeTags` both used to orphan
      // (#645). The fold repoints it, so a tag hint recorded against the loser is
      // still a tag hint after convergence.
      final ids = _idsInMinOrder(['hint-small', 'hint-large']);
      b.goOffline();
      await tagWithId(a, ids.first);
      await tagWithId(b, ids.last);
      final captureId = _id('capture-b');
      await b.domain.captureDao.insertCapture(CapturesCompanion(
        id: Value(captureId),
        title: const Value('ring Alice back'),
        captureSource: const Value('voice'),
        userId: const Value(_userId),
        createdAt: Value(b.clock.asDateTime),
      ));
      await b.domain.captureDao.assignTagHint(captureId, ids.last, _userId);

      b.goOnline();
      await settle([a, b]);

      final hints = await expectConverged([a, b], 'capture_tags');
      expect(hints, hasLength(1));
      expect(hints.single['tag_id'], ids.first,
          reason: 'the hint must follow the fold, not dangle on the loser');
      expect(await personTags(a), hasLength(1));
    });

    test('both arrival orders reach the same rows', () async {
      // Order independence, stated as *identical between two runs* rather than
      // merely internally consistent on each: a fold that picked a device-local
      // survivor would satisfy the weaker claim.
      Future<Map<String, List<Map<String, Object?>>>> run(
        bool aPullsFirst,
      ) async {
        final scenario = await SimWorkspace.create();
        addTearDown(scenario.close);
        await scenario.syncAll();
        final ids = _idsInMinOrder(['order-x', 'order-y']);

        scenario.b.goOffline();
        final outcomeA = await outcomeOn(scenario.a, 'order-outcome-a');
        await tagWithId(scenario.a, ids.last);
        await scenario.a.domain.tagDao.assignTag(outcomeA, ids.last, _userId);
        final outcomeB = await outcomeOn(scenario.b, 'order-outcome-b');
        await tagWithId(scenario.b, ids.first);
        await scenario.b.domain.tagDao.assignTag(outcomeB, ids.first, _userId);
        scenario.b.goOnline();

        await settle(aPullsFirst
            ? [scenario.a, scenario.b]
            : [scenario.b, scenario.a]);
        await expectConverged([scenario.a, scenario.b], 'tags');

        return {
          'tags': await domainRows(scenario.a.domain, 'tags'),
          'todo_tags': await domainRows(scenario.a.domain, 'todo_tags'),
          'capture_tags': await domainRows(scenario.a.domain, 'capture_tags'),
        };
      }

      final aFirst = await run(true);
      final bFirst = await run(false);
      expect(bFirst['tags'], aFirst['tags']);
      expect(bFirst['todo_tags'], aFirst['todo_tags']);
      expect(bFirst['capture_tags'], aFirst['capture_tags']);
    });

    test('a further sync authors nothing and changes nothing', () async {
      // Quiescence, asserted rather than assumed: the fold *writes*, so a fold
      // that re-fired on its own output would author ops for ever.
      b.goOffline();
      final outcomeA = await outcomeOn(a, 'quiet-a');
      final tagA =
          await a.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await a.domain.tagDao.assignTag(outcomeA, tagA, _userId);
      final outcomeB = await outcomeOn(b, 'quiet-b');
      final tagB =
          await b.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      await b.domain.tagDao.assignTag(outcomeB, tagB, _userId);
      b.goOnline();
      await settle([a, b]);

      Future<int> count(SimDevice device, String table) async => (await device
              .database
              .customSelect('SELECT COUNT(*) AS c FROM $table')
              .getSingle())
          .read<int>('c');

      final before = [
        for (final device in [a, b])
          [await count(device, 'op_log'), await count(device, 'outbox')],
      ];
      final rowsBefore = await rowsOnEach([a, b], 'tags');
      final junctionsBefore = await rowsOnEach([a, b], 'todo_tags');

      await settle([a, b]);

      for (var index = 0; index < 2; index++) {
        final device = [a, b][index];
        expect([await count(device, 'op_log'), await count(device, 'outbox')],
            before[index],
            reason: '${device.label} authored or received ops on a quiet sync');
      }
      expect(await rowsOnEach([a, b], 'tags'), rowsBefore);
      expect(await rowsOnEach([a, b], 'todo_tags'), junctionsBefore);
    });
  });

  group('three devices, three duplicates', () {
    test(
        'every assignment lands on the global MIN(id), including one asserted '
        'on a since-tombstoned loser', () async {
      // The §4c scenario. `MIN(id)` is order-independent for the *survivor*, but
      // the fold reads the LOCAL `tags` table, so a device folds to a local
      // minimum. With X < Y < Z:
      //
      //   A folds Z→Y, then goes offline before pushing — and while offline keeps
      //   working, tagging a new Outcome with the tag it believes is live. B and C
      //   meanwhile fold Y→X and tombstone Y. When A rejoins, that junction is an
      //   entity **no other device ever authored**, asserting a tag that is by now
      //   tombstoned under a smaller HLC than the assert. It stays live, its tag
      //   does not, and the `(Alice, person)` group is COUNT = 1 — so no
      //   duplicate-based trigger can ever see it.
      //
      // Only the rehome pass, whose condition is "a junction whose tag_id has no
      // row in tags" and therefore *durable*, recovers that assignment. Without
      // it, all three devices converge on a `todo_tags` row pointing at nothing:
      // a silently-lost Tag assignment rather than a loud failure.
      //
      // Note what the fold gets right on its own: A's *repointed* junction is the
      // derived id `todoTagIdFor(outcome, Y)`, and B — passing through the same
      // intermediate {Y, Z} state — authors and later tombstones that same derived
      // entity, so the intermediate step converges without help. The rehome pass is
      // needed for the assignment B never had a chance to author.
      final workspace = await SimWorkspace.create(deviceCount: 3);
      addTearDown(workspace.close);
      final [a, b, c] = workspace.devices;
      await workspace.syncAll();

      final ids = _idsInMinOrder(['tri-1', 'tri-2', 'tri-3']);
      final x = ids[0];
      final y = ids[1];
      final z = ids[2];

      // Each device mints its own "Alice" offline and assigns it to its own
      // Outcome — three entities for one pair, which is the ordinary multi-device
      // outcome of `findOrCreateTag`.
      b.goOffline();
      c.goOffline();
      final outcomeA = await outcomeOn(a, 'tri-outcome-a');
      await tagWithId(a, z);
      await a.domain.tagDao.assignTag(outcomeA, z, _userId);

      final outcomeB = await outcomeOn(b, 'tri-outcome-b');
      await tagWithId(b, y);
      await b.domain.tagDao.assignTag(outcomeB, y, _userId);

      final outcomeC = await outcomeOn(c, 'tri-outcome-c');
      await tagWithId(c, x);
      await c.domain.tagDao.assignTag(outcomeC, x, _userId);

      // Stage 1: B publishes Y. A pulls it and folds Z→Y — `sync()` pushes *then*
      // pulls, and the fold runs at the pull tail, so A's fold ops are authored
      // into its outbox with no push left to carry them. A then drops off, and
      // nobody else ever learns that A moved its junction onto Y.
      b.goOnline();
      await b.sync();
      await a.sync();
      expect(
        (await personTags(a)).map((row) => row['id']),
        [y],
        reason: 'A folds to the minimum of the pair it can see',
      );
      a.goOffline();

      // Still offline, A tags a new Outcome with the tag it believes is live. This
      // junction entity is A's alone — no other device will ever author it — so
      // nothing will tombstone it when Y goes away.
      final outcomeAOffline = await outcomeOn(a, 'tri-outcome-a-offline');
      await a.domain.tagDao.assignTag(outcomeAOffline, y, _userId);

      // Stage 2: C arrives with X. B and C converge without ever seeing A's fold,
      // so they fold the whole visible group — {X, Y, Z} — onto X, and tombstone Y.
      c.goOnline();
      await settle([b, c], rounds: 3);
      expect((await personTags(b)).map((row) => row['id']), [x]);

      // Stage 3: A rejoins and finally pushes. Its junction-on-Y assertion lands on
      // peers whose Y was tombstoned at a *later* HLC, so the junction stays live
      // while the tag it names does not — and the `(Alice, person)` group is now
      // COUNT = 1, so the fold pass is blind to it. Only the rehome pass recovers
      // this assignment.
      a.goOnline();
      await settle([a, b, c], rounds: 4);

      final tags = await expectConverged([a, b, c], 'tags');
      expect(tags.where((row) => row['name'] == 'Alice').map((row) => row['id']),
          [x],
          reason: 'three duplicates converge on the global MIN(id)');

      final junctions = await expectConverged([a, b, c], 'todo_tags');
      expect(
        junctions.map((row) => row['todo_id']).toSet(),
        {outcomeA, outcomeB, outcomeC, outcomeAOffline},
        reason: 'no assignment was lost on the way through two folds',
      );
      expect(junctions.map((row) => row['tag_id']).toSet(), {x},
          reason: 'no junction left stranded on a tombstoned tag');

      await expectReducedStateAgrees([a, b, c]);
    });
  });

  group('a convergence pass that throws', () {
    test('leaves the pull completed, and is retried on the next one', () async {
      // The regression this guards is the one #605 exists to repair, with the
      // reconciler as the new thrower: ops durable and the cursor advanced, the
      // projection committed, and `_stampPullCompleted` skipped — so the server
      // never re-serves that batch and the device's freshness never moves again.
      // Putting a throwing pass in front of the stamp would rebuild it exactly.
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final a = workspace.a;
      final b = workspace.b;
      await workspace.syncAll();

      // Stage the duplicate, and leave it unpublished on B so the pull under test
      // is the one that first makes the group foldable on B.
      b.goOffline();
      final tagA =
          await a.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      final tagB =
          await b.domain.tagDao.findOrCreateTag('Alice', 'person', _userId);
      expect(tagA, isNot(tagB));
      await a.sync();
      b.goOnline();

      final faulty = _FaultyReconciler(registry: b.registry, domain: b.domain);
      b.client.reconciler = faulty;

      workspace.clock.advance(60000);
      final failedRepair = await b.sync();

      expect(faulty.forcedOnEachCall, [false],
          reason: 'the batch carried a Tag, so the ordinary gate let it through');
      expect(
        (await personTags(b)).map((row) => row['id']).toSet(),
        {tagA, tagB},
        reason: 'the pass really did fail — otherwise the retry proves nothing',
      );
      expect(failedRepair.lastSyncedAt, isNotNull,
          reason: 'a failed repair must not skip the completion stamp: the ops '
              'and the projection are already committed and correct, and the '
              'cursor has already moved past this batch');

      // The next pull carries **nothing** — A has authored nothing since. The
      // collections gate alone would therefore skip the passes and leave the
      // duplicate on screen until unrelated tag traffic happened along; the
      // re-arm is what runs them anyway.
      faulty.armed = false;
      workspace.clock.advance(60000);
      final repaired = await b.sync();

      expect(faulty.forcedOnEachCall, [false, true],
          reason: 'the retry is forced past the batch-derived gate');
      expect(repaired.lastSyncedAt, isNotNull);
      expect(repaired.lastSyncedAt!.isAfter(failedRepair.lastSyncedAt!), isTrue,
          reason: 'both pulls completed');

      final alice = await personTags(b);
      expect(alice, hasLength(1), reason: 'the retry converged');
      expect(alice.single['id'],
          [tagA, tagB].reduce((x, y) => x.compareTo(y) <= 0 ? x : y));

      // And a third quiet pull disarms the re-arm rather than forcing for ever.
      workspace.clock.advance(60000);
      await b.sync();
      expect(faulty.forcedOnEachCall, [false, true, false]);
    });
  });
}

/// The real reconciler, with a fault the pull tail has to survive.
///
/// Injected at the seam `SyncClient.pull` actually calls, so what is under test
/// is the client's containment rather than a restatement of it. Disarmed it
/// delegates to the real passes, which is what makes the retry a retry that
/// genuinely converges instead of one that merely happened.
class _FaultyReconciler extends DomainReconciler {
  _FaultyReconciler({required super.registry, required super.domain});

  bool armed = true;

  /// The `force` argument of every call, in order — the record of *why* each run
  /// happened: `false` is the ordinary batch-derived gate, `true` a re-arm.
  final List<bool> forcedOnEachCall = [];

  @override
  Future<void> reconcile(Set<String> collections, {bool force = false}) async {
    forcedOnEachCall.add(force);
    if (armed) throw StateError('a convergence pass blew up');
    return super.reconcile(collections, force: force);
  }
}
