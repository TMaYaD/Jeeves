/// A change belongs to the Workspace whose log carries it.
///
/// Each Workspace's log carries only its own collections — `user_preferences`
/// in the preferences Workspace, every other collection in the default one — so
/// a change that crosses that line is refused on every Device. The refusal is
/// the logged-but-refused class: the envelope stays in the op log as evidence
/// with the reason stamped, nothing reaches merge state or the domain tables,
/// and the author's chain accounting advances, so the author's next honest
/// change still applies.
///
/// **The journey is the whole story**: a Member granted only the default
/// Workspace posts a change belonging to the preferences Workspace, both
/// Devices refuse it, and the Member's next honest change lands. A unit test on
/// the reducer would prove the rule fires; only the journey proves the user's
/// setting is untouched and the log does not wedge.
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/collection_codecs.dart'
    show todosCollection, userPreferencesCollection;
import 'package:jeeves/sync/control_payload.dart' show roleParticipant;
import 'package:jeeves/sync/hlc.dart' show HlcClock, memberIdToHex;
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/author_fixture.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_workspace.dart';

/// A canonical UUID, because a payload's entity id has to be one.
const String _outcomeId = '55555555-5555-4555-8555-555555555555';

void main() {
  group('a change whose collection belongs to another Workspace', () {
    test('is refused on every Device, and the author\'s next honest change '
        'still applies', () async {
      final workspace = await SimWorkspace.create(deviceCount: 2);
      addTearDown(workspace.close);
      final a = workspace.a;
      final b = workspace.b;

      // Device A sets a preference and everything syncs. This is the value the
      // refusal has to protect: a user's own setting, on their own Devices.
      await a.preferences.set('theme', '"light"');
      await workspace.syncAll();
      expect(await a.preferences.get('theme'), '"light"');
      expect(await b.preferences.get('theme'), '"light"');
      final stateBeforeA = await canonicalReducedState(a.database);
      final stateBeforeB = await canonicalReducedState(b.database);

      // A Member granted only the default Workspace. It is the only Workspace a
      // Service can be granted, and the role it needs to author content at all.
      final service = await AuthorFixture.create();
      final session =
          await workspace.enrolServiceFixture(service, role: roleParticipant);
      await workspace.syncAll();

      // The Member posts a preference write into the default Workspace's log,
      // under a clock later than the honest write it would have to beat.
      workspace.clock.advance(1000);
      final misrouted = await service.nextEnvelope(
        workspace.workspaceId,
        payloadJson: jsonEncode({
          'collection': userPreferencesCollection,
          'id': preferenceEntityId(workspace.preferencesWorkspaceId, 'theme'),
          'fields': {
            'key': {'v': 'theme'},
            'value': {'v': '"dark"'},
          },
          'hlc': [workspace.clock.nowMs, 0, memberIdToHex(service.memberId)],
        }),
      );
      final appended = await session.postOps(workspace.workspaceId, [misrouted]);
      final misroutedSeq = appended.single.seq;

      await workspace.syncAll();

      // Neither Device applied it: the setting still reads as the user set it,
      // and no merge state moved.
      expect(await a.preferences.get('theme'), '"light"',
          reason: 'the refused change did not overwrite the user\'s setting');
      expect(await b.preferences.get('theme'), '"light"');
      expect(await canonicalReducedState(a.database), stateBeforeA);
      expect(await canonicalReducedState(b.database), stateBeforeB);

      // The envelope is still there, as evidence, with the refusal stamped on
      // it. Both Devices reached the same verdict.
      for (final device in [a, b]) {
        final row = await (device.database.select(device.database.opLog)
              ..where((row) =>
                  row.workspaceId.equals(workspace.workspaceId) &
                  row.seq.equals(misroutedSeq)))
            .getSingle();
        expect(row.refusedReason, 'collection_outside_workspace');
        expect(row.appliedAt, isNull, reason: 'the op never applied');
      }

      // The author's chain accounting advanced, so its next honest change
      // applies. A refusal that wedged the chain would have quarantined every
      // later op from the same author.
      workspace.clock.advance(1000);
      final honest = await service.nextEnvelope(
        workspace.workspaceId,
        payloadJson: jsonEncode({
          'collection': todosCollection,
          'id': _outcomeId,
          'fields': {
            'title': {'v': 'An honest note'},
            'created_at': {'v': '2026-02-01T09:00:00.000Z'},
            'user_id': {'v': workspace.userId},
          },
          'hlc': [workspace.clock.nowMs, 0, memberIdToHex(service.memberId)],
        }),
      );
      await session.postOps(workspace.workspaceId, [honest]);
      await workspace.syncAll();

      final stateAfterA = await canonicalReducedState(a.database);
      final stateAfterB = await canonicalReducedState(b.database);
      expect(stateAfterA, isNot(stateBeforeA),
          reason: "the author's next honest change applied");
      expect(stateAfterB, stateAfterA, reason: 'and both Devices agree on it');
      expect(stateAfterA, contains('An honest note'));
    });
  });

  group('a client paired with another Workspace\'s reducer', () {
    test('is refused at construction', () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final database = SyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final identity = await MemberIdentity.generate();
      const userId = 'boundary-user';

      // The rule lives on the reducer, and the reducer knows which Workspace it
      // is reducing. A client paired with another Workspace's reducer would
      // refuse every honest change, so the pairing is refused outright rather
      // than left to be discovered as a device that quietly mis-reduces.
      final preferencesReducer = Reducer(
        database,
        nowMs: () => 1770000000000,
        workspaceId: userPreferencesWorkspaceId(userId),
        userId: userId,
      );

      expect(
        () => SyncClient(
          workspaceId: defaultWorkspaceId(userId),
          userId: userId,
          identity: identity,
          database: database,
          clock: HlcClock(memberIdHex: identity.memberIdHex, nowMs: () => 0),
          reducer: preferencesReducer,
        ),
        throwsArgumentError,
      );
    });
  });
}
