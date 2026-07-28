/// End-to-end: two simulated devices converge through the op log.
///
/// This file is the acceptance criteria of #546. Every case runs the whole
/// spine — local write → signed envelope → server log → pull → verify →
/// reduce — in one process, on a fake clock, with no PowerSync engine in sight.
/// That last part is the point: `docs/SYNC.md` records zero automated coverage
/// of the engine path, and closing that gap is one of ADR-0026's motivations.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';
import 'vectors.dart';

/// The spec user, so the golden negative vectors — which are signed over the
/// spec workspace id — can be injected into this workspace verbatim.
const String _specUserId = 'spec-user-1';

const String _harnessCollection = 'harness_docs';

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}

Future<List<Uint8List>> _opLogEnvelopes(SimDevice device) async {
  final rows = await (device.database.select(device.database.opLog)
        ..orderBy([(row) => OrderingTerm(expression: row.seq)]))
      .get();
  return [for (final row in rows) row.envelope];
}

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(userId: _specUserId);
  });

  tearDown(() => workspace.close());

  // --- AC 1 -----------------------------------------------------------------

  test('two devices converge a user_preferences edit in both directions',
      () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();
    expect(await workspace.b.preferences.get('theme'), '"dark"');

    workspace.clock.advance(1000);
    await workspace.b.preferences.set('theme', '"light"');
    await workspace.syncAll();
    expect(await workspace.a.preferences.get('theme'), '"light"');
    expect(await workspace.b.preferences.get('theme'), '"light"');
  });

  test('a deletion converges as a tombstone, not as row absence', () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.a.preferences.set('font', '"serif"');
    await workspace.syncAll();
    expect(await workspace.b.preferences.getAll(),
        {'theme': '"dark"', 'font': '"serif"'});

    workspace.clock.advance(1000);
    await workspace.b.preferences.delete('theme');
    await workspace.syncAll();
    expect(await workspace.a.preferences.get('theme'), isNull);
    expect(await workspace.a.preferences.getAll(), {'font': '"serif"'});
  });

  test('both devices creating the same preference offline converge as one row',
      () async {
    // The entity id is uuid5(workspace, key), so the two writes are edits of
    // one entity rather than two rows racing a unique constraint.
    workspace.b.goOffline();
    await workspace.a.preferences.set('theme', '"dark"');
    workspace.clock.advance(1000);
    await workspace.b.preferences.set('theme', '"light"');

    workspace.b.goOnline();
    await workspace.syncAll();

    expect(await workspace.a.preferences.getAll(), {'theme': '"light"'});
    expect(await workspace.b.preferences.getAll(), {'theme': '"light"'});
  });

  // --- AC 2 -----------------------------------------------------------------

  test('offline edits queue and converge on reconnect', () async {
    workspace.b.goOffline();
    for (final key in ['one', 'two', 'three']) {
      workspace.clock.advance(100);
      await workspace.b.preferences.set(key, '"$key"');
    }
    workspace.clock.advance(100);
    await workspace.a.preferences.set('from_a', '"a"');
    await workspace.syncAll();
    expect(await workspace.a.preferences.getAll(), {'from_a': '"a"'});

    workspace.b.goOnline();
    await workspace.syncAll();

    const expected = {
      'one': '"one"',
      'two': '"two"',
      'three': '"three"',
      'from_a': '"a"',
    };
    expect(await workspace.a.preferences.getAll(), expected);
    expect(await workspace.b.preferences.getAll(), expected);
  });

  test('replaying an already-accepted batch is a no-op', () async {
    workspace.clock.advance(100);
    await workspace.b.preferences.set('one', '"one"');
    workspace.clock.advance(100);
    await workspace.b.preferences.set('two', '"two"');
    await workspace.syncAll();

    final stateBefore = await workspace.a.preferences.getAll();
    final logBefore = await _opLogEnvelopes(workspace.a);

    final replayed = await workspace.b.client.authoredEnvelopes();
    final results = await workspace.b.link.postOps(workspace.workspaceId, replayed);
    expect(results.map((result) => result.duplicate), everyElement(isTrue));

    await workspace.syncAll();
    expect(await workspace.a.preferences.getAll(), stateBefore);
    expect(await _opLogEnvelopes(workspace.a), logBefore);
  });

  test('a lost POST response re-sends and dedupes rather than duplicating',
      () async {
    workspace.clock.advance(100);
    await workspace.a.preferences.set('theme', '"dark"');

    // The server appended; the acknowledgement never came back.
    workspace.a.link.dropPostResponse = true;
    await expectLater(
      workspace.a.client.flushOutbox(),
      throwsA(isA<SyncTransportException>()),
    );
    workspace.a.link.dropPostResponse = false;

    await workspace.syncAll();
    expect(await workspace.b.preferences.getAll(), {'theme': '"dark"'});
    expect((await _opLogEnvelopes(workspace.b)).length, 1);
  });

  // --- AC 5 -----------------------------------------------------------------

  test('concurrent edits to different fields of one row both survive',
      () async {
    // user_preferences rows have one field that changes, so the field-grain
    // case needs a two-field collection. Registering one here also exercises
    // the extension point #550 hangs its collections off.
    final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
    final viewA = workspace.a.registry.register(_harnessCollection);
    final viewB = workspace.b.registry.register(_harnessCollection);

    // Same fake-clock reading on both devices: genuinely concurrent HLCs.
    await workspace.a.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_a'},
    );
    await workspace.b.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'b': 'from_b'},
    );
    await workspace.syncAll();

    const expected = {'a': 'from_a', 'b': 'from_b'};
    expect(await viewA.readEntity(docId), expected);
    expect(await viewB.readEntity(docId), expected);
  });

  test('concurrent edits to the same field resolve identically on both devices',
      () async {
    final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
    final viewA = workspace.a.registry.register(_harnessCollection);
    final viewB = workspace.b.registry.register(_harnessCollection);

    await workspace.a.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_a'},
    );
    await workspace.b.client.capture(
      collection: _harnessCollection,
      entityId: docId,
      fields: {'a': 'from_b'},
    );
    await workspace.syncAll();

    // Equal wall_ms and counter, so the member id decides — and the point is
    // that both devices decide the same way, not which one wins.
    final winner = (await viewA.readEntity(docId))!['a'];
    expect(await viewB.readEntity(docId), {'a': winner});
    final higherMember = [
      workspace.a.identity.memberIdHex,
      workspace.b.identity.memberIdHex,
    ]..sort();
    expect(
      winner,
      higherMember.last == workspace.a.identity.memberIdHex ? 'from_a' : 'from_b',
    );
  });

  // --- AC 4 -----------------------------------------------------------------

  test('the golden negative vectors quarantine and never apply', () async {
    final document = envelopeVectors();
    final identities = document['identities'] as Map<String, dynamic>;
    // The spec keys must be in the registry, or every vector would stop at the
    // unknown-key check instead of reaching the rule it exists to exercise.
    final adminSession = workspace.server.connectAs(_specUserId);
    for (final entry in identities['keys'] as List<dynamic>) {
      final key = entry as Map<String, dynamic>;
      await adminSession.registerMember(
        memberId: key['member_id'] as String,
        signPk: _fromHex(key['sign_pk_hex'] as String),
      );
    }

    final negatives = vectorList(document, 'negative_vectors');
    for (final vector in negatives) {
      workspace.server.injectUnchecked(
        workspace.workspaceId,
        _fromHex(vector['envelope_hex'] as String),
      );
    }

    // A valid op after the bad ones: the stream must not stall on refusal.
    workspace.clock.advance(1000);
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();

    for (final device in workspace.devices) {
      final quarantined = await device.client.quarantined();
      expect(
        quarantined.map((row) => row.reason).toList(),
        negatives.map((vector) => vector['reason']).toList(),
        reason: 'device ${device.label}',
      );
      expect(await device.preferences.getAll(), {'theme': '"dark"'});
      // Nothing refused reached the log: quarantine is not a soft filter.
      expect((await _opLogEnvelopes(device)).length, 1);
    }
  });

  test('an op from an unregistered key quarantines rather than being trusted',
      () async {
    final stranger = await AuthorFixture.create(
      seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 11)),
    );
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await stranger.nextEnvelope(workspace.workspaceId),
    );

    await workspace.a.sync();
    final quarantined = await workspace.a.client.quarantined();
    expect(quarantined.single.reason, SyncRejectionReason.unknownAuthorKey.code);
  });

  test('the quarantine count is watchable so a refusal can be surfaced',
      () async {
    expect(await workspace.a.client.watchQuarantineCount().first, 0);
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      _fromHex(
        vectorList(envelopeVectors(), 'negative_vectors')
            .firstWhere((vector) => vector['name'] == 'unknown_suite')['envelope_hex']
            as String,
      ),
    );
    await workspace.a.sync();
    expect(await workspace.a.client.watchQuarantineCount().first, 1);
  });

  // --- Reducer guards over the full path ---------------------------------------

  group('reducer guards', () {
    /// The server is content-blind, so these bodies go through the *real* POST
    /// path: nothing server-side could have caught them, which is exactly why
    /// the guards live on the receiving client.
    Future<AuthorFixture> registerRogue() async {
      final rogue = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 21)),
      );
      await workspace.server
          .connectAs(_specUserId)
          .registerMember(memberId: rogue.memberId, signPk: rogue.signPk);
      return rogue;
    }

    Future<void> postPayload(AuthorFixture rogue, Map<String, Object?> payload) async {
      final envelope = await rogue.nextEnvelope(
        workspace.workspaceId,
        payloadJson: jsonEncode(payload),
      );
      await workspace.server
          .connectAs(_specUserId)
          .postOps(workspace.workspaceId, [envelope]);
    }

    test('an op-level HLC far in the future quarantines', () async {
      final rogue = await registerRogue();
      await postPayload(rogue, {
        'collection': _harnessCollection,
        'id': preferenceEntityId(workspace.workspaceId, 'harness-doc'),
        'fields': {
          'a': {'v': 'from_the_future'},
        },
        'hlc': [
          workspace.clock.nowMs + 3600000,
          0,
          memberIdToHex(rogue.memberId),
        ],
      });

      await workspace.a.sync();
      final quarantined = await workspace.a.client.quarantined();
      expect(quarantined.single.reason, SyncRejectionReason.hlcInTheFuture.code);
      expect(
        await workspace.a.registry.register(_harnessCollection).readAll(),
        isEmpty,
      );
    });

    test('an op whose HLC member is not the header author quarantines',
        () async {
      final rogue = await registerRogue();
      await postPayload(rogue, {
        'collection': _harnessCollection,
        'id': preferenceEntityId(workspace.workspaceId, 'harness-doc'),
        'fields': {
          'a': {'v': 'impersonated'},
        },
        'hlc': [
          workspace.clock.nowMs,
          0,
          workspace.a.identity.memberIdHex,
        ],
      });

      await workspace.a.sync();
      final quarantined = await workspace.a.client.quarantined();
      expect(
        quarantined.single.reason,
        SyncRejectionReason.hlcMemberIsNotAuthor.code,
      );
    });

    test('a per-field HLC from another member in the past still applies',
        () async {
      // The F15 exemption, end to end: this is the shape a compaction op
      // (#555) has, and quarantining it would make compaction impossible.
      final rogue = await registerRogue();
      final docId = preferenceEntityId(workspace.workspaceId, 'harness-doc');
      await postPayload(rogue, {
        'collection': _harnessCollection,
        'id': docId,
        'fields': {
          'a': {
            'v': 'reasserted',
            'hlc': [
              workspace.clock.nowMs - 60000,
              7,
              workspace.b.identity.memberIdHex,
            ],
          },
        },
        'hlc': [workspace.clock.nowMs, 0, memberIdToHex(rogue.memberId)],
      });

      await workspace.a.sync();
      expect(await workspace.a.client.quarantined(), isEmpty);
      expect(
        await workspace.a.registry.register(_harnessCollection).readEntity(docId),
        {'a': 'reasserted'},
      );
    });
  });

  // --- Chain and evidence ---------------------------------------------------

  test('authored envelopes chain by author_seq and prev_author_hash', () async {
    for (var index = 0; index < 3; index++) {
      workspace.clock.advance(100);
      await workspace.a.preferences.set('key$index', '"$index"');
    }
    final authored = await workspace.a.client.authoredEnvelopes();
    expect(authored.length, 3);

    var expectedPrevHash = Uint8List(prevAuthorHashBytes);
    for (var index = 0; index < authored.length; index++) {
      final header = OpHeader.parse(authored[index]);
      expect(header.authorSeq, index + 1);
      expect(header.prevAuthorHash, expectedPrevHash);
      expect(header.authorMemberId, workspace.a.identity.memberId);
      expect(header.workspaceId, workspace.workspaceId);
      expectedPrevHash = envelopeHash(authored[index]);
    }
  });

  test('the op log keeps received envelopes byte-identical', () async {
    await workspace.a.preferences.set('theme', '"dark"');
    await workspace.syncAll();
    expect(
      await _opLogEnvelopes(workspace.b),
      await workspace.a.client.authoredEnvelopes(),
    );
  });
}
