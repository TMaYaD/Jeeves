/// The production capture binding: where an op goes, and when none is authored.
///
/// Routing is asserted by reading the **outbox**, not by watching a spy: the
/// `workspace_id` a queued envelope carries is the whole claim, and a stub client
/// could agree with the router while the store disagreed with both.
///
/// No transport is attached to either client, deliberately. `capture()` authors,
/// queues, reduces and projects locally without one — which is what makes a
/// bound-but-offline device queue correctly rather than lose the write.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

const String _userId = 'routing-user';
const int _nowMs = 1770000000000;

/// A canonical UUID, because `capture()` refuses a non-canonical entity id at the
/// author's own call site (#573).
const String _outcomeId = '55555555-5555-4555-8555-555555555555';

/// A member id that is nobody's: the clock of a change made before this device
/// enrolled, and the one the bridge declines to author.
const String _otherMemberIdHex = 'ffffffffffffffffffffffffffffffff';

void main() {
  setUpAll(configureSqliteForTests);

  late SyncDatabase database;
  late SyncClient gtdClient;
  late SyncClient preferencesClient;
  late WorkspaceRoutingOpCapture capture;
  late MemberIdentity identity;

  /// The changes the bridge reported as ones it will never author.
  late List<UnauthoredClock> reported;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    identity = await MemberIdentity.generate();
    final clock = HlcClock(memberIdHex: identity.memberIdHex, nowMs: () => _nowMs);
    SyncClient clientFor(String workspaceId) => SyncClient(
          workspaceId: workspaceId,
          userId: _userId,
          identity: identity,
          database: database,
          clock: clock,
          reducer: Reducer(database, nowMs: () => _nowMs),
          now: () => DateTime.fromMillisecondsSinceEpoch(_nowMs, isUtc: true),
        );
    gtdClient = clientFor(defaultWorkspaceId(_userId));
    preferencesClient = clientFor(userPreferencesWorkspaceId(_userId));
    capture = WorkspaceRoutingOpCapture();
    reported = <UnauthoredClock>[];
    capture.onChangesLeftUnauthored = (unauthored) async {
      reported.addAll(unauthored);
    };
  });

  Future<List<String>> queuedWorkspaceIds() async {
    final rows = await (database.select(database.outbox)
          ..orderBy([(row) => OrderingTerm.asc(row.id)]))
        .get();
    return [for (final row in rows) row.workspaceId];
  }

  /// The shape `GtdDatabase.capturing` produces: the scope is opened, the body
  /// runs *inside* it, and only then does it commit. A described effect is filed
  /// into the ambient scope, so a body run outside one is refused.
  Future<void> capturing(void Function() body) async {
    final scope = capture.beginScope();
    await capture.runInScope(scope, () async => body());
    await capture.commitScope(scope);
  }

  void writeOutcome() => capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {
          'title': 'Write the thing',
          'created_at': '2026-02-01T09:00:00.000Z',
          'user_id': _userId,
        },
      );

  /// A preference stored under [userId].
  ///
  /// The entity id derives from *that* user's preferences Workspace, which is
  /// what makes a row stored under `'local'` name an entity the account's
  /// Workspace does not hold.
  void writePreferenceFor(String userId) => capture.write(
        collection: userPreferencesCollection,
        entityId: preferenceEntityId(
          userPreferencesWorkspaceId(userId),
          'clarify_mode',
        ),
        fields: {
          'key': 'clarify_mode',
          'value': '"oneToOne"',
          'updated_at': '2026-02-01T09:00:00.000Z',
          'user_id': userId,
        },
      );

  void writePreference() => writePreferenceFor(_userId);

  /// A change the sync host merged and handed to the bridge: field-grain, with
  /// the clock it stamped.
  ///
  /// The clock names the bound member by default, so the op is that member's to
  /// author. A different member id is the "made before this device enrolled"
  /// case — the one the wire refuses and the bridge declines.
  Change hostChange({String? clockMemberIdHex, String entityId = _outcomeId}) {
    final clock = Hlc(_nowMs, 0, clockMemberIdHex ?? identity.memberIdHex);
    return Change(
      collection: todosCollection,
      entityId: entityId,
      fields: {
        'title': ClockedValue('Write the thing', clock),
        'created_at': ClockedValue('2026-02-01T09:00:00.000Z', clock),
        'user_id': ClockedValue(_userId, clock),
      },
    );
  }

  test('undecided, ops are held — nothing authored until a decision', () async {
    await capturing(() {
      writeOutcome();
      writePreference();
    });

    // Buffered, not dropped: the seam has reached no decision, so neither client
    // has anything queued and the store holds no reduced state. What proves they
    // were *held* rather than lost is the next test, where a later bind drains
    // exactly these ops.
    expect(capture.isBound, isFalse);
    expect(await queuedWorkspaceIds(), isEmpty);
    expect(await database.select(database.reducedFields).get(), isEmpty);
  });

  test('a preference goes to the preferences Workspace, everything else to GTD',
      () async {
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    await capturing(writeOutcome);
    await capturing(writePreference);

    expect(await queuedWorkspaceIds(), [
      defaultWorkspaceId(_userId),
      userPreferencesWorkspaceId(_userId),
    ]);
  });

  test('a preference stored under another user id is not authored', () async {
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    // Stored under the signed-out user id, so its entity id derives from the
    // `'local'` preferences Workspace — an entity this account's Workspace does
    // not hold. Authoring it would put a row under another user's id on the
    // account's log, where the account's other devices would read it.
    await capturing(() => writePreferenceFor('local'));
    expect(await queuedWorkspaceIds(), isEmpty,
        reason: "a row stored under 'local' is not this Workspace's to author");

    // The account's own row is authored.
    await capturing(() => writePreferenceFor(_userId));
    expect(await queuedWorkspaceIds(), [userPreferencesWorkspaceId(_userId)]);
  });

  test('a buffered preference under another user id is discarded by the drain, '
      'and the op queued behind it still authors', () async {
    // Written while undecided, so both ops sit in the buffer: the preference
    // first, then the Outcome behind it.
    await capturing(() => writePreferenceFor('local'));
    await capturing(writeOutcome);
    expect(await queuedWorkspaceIds(), isEmpty, reason: 'held while undecided');

    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    // The preference is discarded, and the discard is not a reason to strand
    // the op queued behind it.
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)],
        reason: 'the discarded preference does not hold the drain open');
  });

  test('binding drains ops buffered while undecided, in write order', () async {
    // Two ops emitted before any decision — one to each Workspace — then bind.
    await capturing(writeOutcome);
    await capturing(writePreference);
    expect(await queuedWorkspaceIds(), isEmpty, reason: 'held while undecided');

    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    expect(await queuedWorkspaceIds(), [
      defaultWorkspaceId(_userId),
      userPreferencesWorkspaceId(_userId),
    ], reason: 'drained on bind, in the order they were written');
  });

  test('a poisoned buffered op is skipped, the rest of the buffer still drains',
      () async {
    // A non-canonical entity id `capture()` refuses (#573), buffered ahead of a
    // healthy op. The refusal must not strand the op queued behind it.
    await capturing(() => capture.write(
          collection: todosCollection,
          entityId: 'NOT-A-UUID',
          fields: {'title': 'poison', 'user_id': _userId},
        ));
    await capturing(writeOutcome);

    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    // Only the healthy op reached the outbox; the refusal was skipped, not fatal.
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
  });

  test('unbinding restores the pre-enrolment state', () async {
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    await capturing(writeOutcome);
    capture.unbind();
    await capturing(writePreference);

    expect(capture.isBound, isFalse);
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
  });

  test('unbind from undecided discards the buffer; a later bind authors only '
      'post-bind writes', () async {
    // Buffered while undecided, then the decision is "author nothing".
    await capturing(writeOutcome);
    capture.unbind();
    expect(capture.isBound, isFalse);

    // A second unbind is a no-op.
    capture.unbind();

    // A write while silent is dropped, not buffered.
    await capturing(writePreference);
    expect(await queuedWorkspaceIds(), isEmpty);

    // A later bind authors only what is written after it — the pre-unbind buffer
    // is gone, so this is the enrolment-after-signed-out contract.
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    await capturing(writeOutcome);
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
  });

  test('the authored-op hook fires once per drained or live op, never for a '
      'buffered or dropped one', () async {
    var authored = 0;
    capture.onOpAuthored = () => authored++;

    // Buffered while undecided: authoring has not happened yet.
    await capturing(writeOutcome);
    expect(authored, 0, reason: 'a buffered op is not an authored one');

    // Bind drains the buffered op — that is when it authors, and fires once.
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    expect(authored, 1, reason: 'the drained op authored on bind');

    // Two more live ops, two more fires.
    await capturing(() {
      writeOutcome();
      writePreference();
    });
    expect(authored, 3);
  });

  test('buffering, coalescing and rollback are the shared ones', () async {
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);

    // Three writes to one entity inside one scope are one op.
    await capturing(() {
      writeOutcome();
      capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {'notes': 'first'},
      );
      capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {'notes': 'second'},
      );
    });
    expect(await queuedWorkspaceIds(), hasLength(1));

    // A rolled-back scope authors nothing, so nothing rolled back is ever signed.
    final rolledBack = capture.beginScope();
    await capture.runInScope(rolledBack, () async => writePreference());
    capture.rollbackScope(rolledBack);
    expect(await queuedWorkspaceIds(), hasLength(1));
  });

  test('a committed write reaches the outbox even when an overlapping scope '
      'rolls back', () async {
    // The loss direction of #562, over the real clients and the real outbox —
    // the half no recording double can demonstrate, because what is lost is the
    // *queued envelope*, not a recorded call.
    //
    // A real domain store, because the claim is about a row that committed and
    // an op that did not follow it. `capturing` opens its scope as its first
    // synchronous statement while its body waits behind drift's `ensureOpen`, so
    // two un-awaited calls always both open before either body runs: filing a
    // write into the scope begun most recently puts A's op in B's buffer, and
    // B's `rollbackScope` then clears it. Committed row, no op, for ever.
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    final domain = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    addTearDown(domain.close);

    final committed = domain.capturing(() => domain.todoDao.insertOutcome(
          id: _outcomeId,
          title: 'Write the thing',
          userId: _userId,
          now: DateTime.fromMillisecondsSinceEpoch(_nowMs, isUtc: true),
        ));
    // The expectation is attached before either is awaited: the rolled-back call
    // can reject while the committed one is still in flight, and an unobserved
    // rejection would surface as an unhandled error rather than as this
    // assertion.
    final refused = expectLater(
      domain.capturing(() async => throw StateError('rolled back')),
      throwsStateError,
    );
    await committed;
    await refused;

    expect(await domain.todoDao.getTodo(_outcomeId), isNotNull,
        reason: 'the write committed to the domain store');
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)],
        reason: "the committed row's op must be queued, not discarded with the "
            "overlapping scope's buffer");
  });

  group('the changes the bridge will never author', () {
    test('unbind from undecided reports the host-clocked ops it discards',
        () async {
      await capture.onLocalChanges([hostChange()]);
      expect(reported, isEmpty,
          reason: 'nothing is left unauthored while the decision is undecided');

      capture.unbind();
      await capture.unauthoredHandedBack;

      expect(reported, hasLength(1));
      expect(reported.single.collection, todosCollection);
      expect(reported.single.entityId, _outcomeId);
      expect(reported.single.clock.memberIdHex, identity.memberIdHex);
    });

    test('an op arriving after the silent decision is reported', () async {
      capture.unbind();
      await capture.unauthoredHandedBack;
      expect(reported, isEmpty, reason: 'there was nothing to discard');

      await capture.onLocalChanges([hostChange()]);
      await capture.unauthoredHandedBack;

      expect(reported, hasLength(1));
      expect(reported.single.entityId, _outcomeId);
      expect(await queuedWorkspaceIds(), isEmpty,
          reason: 'a silent op is never authored');
    });

    test('an op clocked for a member other than the bound one is reported',
        () async {
      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);

      await capture
          .onLocalChanges([hostChange(clockMemberIdHex: _otherMemberIdHex)]);
      await capture.unauthoredHandedBack;

      expect(reported, hasLength(1));
      expect(reported.single.clock.memberIdHex, _otherMemberIdHex);
      expect(await queuedWorkspaceIds(), isEmpty,
          reason: 'the wire refuses an op whose clock does not name its author');
    });

    test('an op authored on bind is not reported, and one outbox row exists',
        () async {
      await capture.onLocalChanges([hostChange()]);
      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);
      await capture.unauthoredHandedBack;

      expect(reported, isEmpty,
          reason: 'the op was authored, not left unauthored');
      expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
    });

    test('an op with no host clock is not reported', () async {
      // Described straight through the seam: no host stamped it, so there is
      // nothing in merge state to take back.
      await capturing(writeOutcome);

      capture.unbind();
      await capture.unauthoredHandedBack;

      expect(reported, isEmpty,
          reason: 'an op with no clock left no clock behind');
    });

    test('a sink that throws does not stop unbind, and the hand-back still '
        'completes', () async {
      capture.onChangesLeftUnauthored = (_) async {
        throw StateError('the host is gone');
      };
      await capture.onLocalChanges([hostChange()]);

      capture.unbind();
      await capture.unauthoredHandedBack;

      expect(capture.isBound, isFalse);
    });
  });

  group('the changes the bridge has settled', () {
    /// The changes the bridge reported as settled — authored, or refused.
    late List<UnauthoredClock> settled;

    setUp(() {
      settled = <UnauthoredClock>[];
      capture.onChangeAuthoredOrRefused = (clock) async => settled.add(clock);
    });

    test('an authored op reports its clock, and one outbox row exists',
        () async {
      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);

      await capture.onLocalChanges([hostChange()]);

      expect(settled, hasLength(1));
      expect(settled.single.collection, todosCollection);
      expect(settled.single.entityId, _outcomeId);
      expect(settled.single.clock.memberIdHex, identity.memberIdHex);
      expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
    });

    test('an op the wire refuses is reported', () async {
      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);

      // A non-canonical entity id is refused at the author's own call site
      // (#573): the op never reaches the outbox, and never will.
      await capture.onLocalChanges([hostChange(entityId: 'NOT-A-UUID')]);

      expect(settled, hasLength(1));
      expect(settled.single.entityId, 'NOT-A-UUID');
      expect(settled.single.clock.memberIdHex, identity.memberIdHex);
      expect(await queuedWorkspaceIds(), isEmpty,
          reason: 'a refused op never reaches the outbox');
    });

    test('an op buffered while undecided is reported only when bind authors '
        'it', () async {
      await capture.onLocalChanges([hostChange()]);
      expect(settled, isEmpty, reason: 'a buffered op is not an authored one');

      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);

      expect(settled, hasLength(1));
      expect(settled.single.entityId, _outcomeId);
    });

    test('an op with no host clock is not reported', () async {
      await capture.bind(
          gtdClient: gtdClient, preferencesClient: preferencesClient);

      // Described straight through the seam: no host stamped it, so there is
      // no record to forget.
      await capturing(writeOutcome);

      expect(settled, isEmpty,
          reason: 'an op with no clock left no clock behind');
    });
  });
}
