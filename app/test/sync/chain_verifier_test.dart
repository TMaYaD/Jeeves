/// The chain rules themselves: the verdict matrix, the release loop, the store.
///
/// Three layers, smallest first. [chainVerdict] is pure, so the whole matrix runs
/// with no database and no clock — including the dormant #555 floor, which has to
/// be right *before* anything supplies one, because the rule it encodes is what
/// keeps an honest post-compaction bootstrap from reading as an alarm storm.
/// Above it, the release loop's fixpoint over a deep reorder. Above that, the
/// migration a device that already holds a log will actually run.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:sqlite3/sqlite3.dart' as raw;

import 'harness/author_fixture.dart';
import 'harness/sim_workspace.dart';

const String _workspaceId = '7af3026d-8599-55e0-9861-18d0f42ecbf3';
const String _harnessCollection = 'harness_docs';

/// One minted op: the envelope and the header parsed back out of it.
typedef _Op = ({OpHeader header, Uint8List envelope});

Future<_Op> _mint(
  AuthorFixture author, {
  int? authorSeq,
  String? opId,
  String payloadJson = '{"collection":"test"}',
  bool advance = true,
}) async {
  final envelope = await author.nextEnvelope(
    _workspaceId,
    authorSeq: authorSeq,
    opId: opId,
    payloadJson: payloadJson,
    advance: advance,
  );
  return (header: OpHeader.parse(envelope), envelope: envelope);
}

Uint8List _someHash(int fill) =>
    Uint8List.fromList(List<int>.filled(prevAuthorHashBytes, fill));

void main() {
  group('the verdict matrix', () {
    late AuthorFixture author;

    setUp(() async {
      author = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 3)),
      );
    });

    test('op 1 with the zero hash starts a chain this device has never seen',
        () async {
      final op = await _mint(author);
      expect(op.header.authorSeq, 1);
      expect(chainVerdict(header: op.header, envelope: op.envelope).outcome,
          ChainOutcome.accept);
    });

    test('op 1 with a non-zero prev hash is a linkage mismatch, not a fresh start',
        () async {
      // A device that skipped a pull would emit this, and so would a server
      // fabricating a chain: either way there is nothing here for it to link to.
      author.lastEnvelopeHash = _someHash(0x11);
      final op = await _mint(author);
      final verdict = chainVerdict(header: op.header, envelope: op.envelope);
      expect(verdict.rejection!.reason, SyncRejectionReason.prevAuthorHashMismatch);
      expect(verdict.alarm, IntegrityAlarmKind.prevAuthorHashMismatch);
    });

    test('head + 1 naming the head is accepted', () async {
      final first = await _mint(author);
      final second = await _mint(author);
      expect(
        chainVerdict(
          header: second.header,
          envelope: second.envelope,
          head: (authorSeq: 1, envelopeHash: envelopeHash(first.envelope)),
        ).outcome,
        ChainOutcome.accept,
      );
    });

    test('head + 1 naming something else is a prev-hash mismatch', () async {
      await _mint(author);
      final second = await _mint(author);
      final verdict = chainVerdict(
        header: second.header,
        envelope: second.envelope,
        head: (authorSeq: 1, envelopeHash: _someHash(0x22)),
      );
      expect(verdict.rejection!.reason, SyncRejectionReason.prevAuthorHashMismatch);
    });

    test('a jump past head + 1 is a gap, and does not move the head', () async {
      final first = await _mint(author);
      await _mint(author); // authored but withheld
      final third = await _mint(author);
      final head = (authorSeq: 1, envelopeHash: envelopeHash(first.envelope));
      final verdict =
          chainVerdict(header: third.header, envelope: third.envelope, head: head);
      expect(verdict.rejection!.reason, SyncRejectionReason.authorChainGap);
      expect(verdict.alarm, IntegrityAlarmKind.authorChainGap);
      // No latching: the same head is still the head, so the next op is judged
      // against what this device verified rather than what the server claimed.
      expect(
        chainVerdict(header: third.header, envelope: third.envelope, head: head)
            .rejection!
            .reason,
        SyncRejectionReason.authorChainGap,
      );
    });

    test('a position already held, byte-identical, is an idempotent skip',
        () async {
      final op = await _mint(author);
      expect(
        chainVerdict(
          header: op.header,
          envelope: op.envelope,
          head: (authorSeq: 1, envelopeHash: envelopeHash(op.envelope)),
          storedAtAuthorSeq: (authorSeq: 1, envelope: op.envelope),
        ).outcome,
        ChainOutcome.idempotentSkip,
      );
    });

    test('a position already held, with different bytes, is a rewrite', () async {
      final held = await _mint(author, advance: false);
      final substitute = await _mint(author, advance: false);
      expect(held.envelope, isNot(substitute.envelope));
      final verdict = chainVerdict(
        header: substitute.header,
        envelope: substitute.envelope,
        head: (authorSeq: 1, envelopeHash: envelopeHash(held.envelope)),
        storedAtAuthorSeq: (authorSeq: 1, envelope: held.envelope),
      );
      expect(verdict.rejection!.reason, SyncRejectionReason.authorChainRewrite);
      expect(verdict.alarm, IntegrityAlarmKind.authorChainRewrite);
    });

    test('a position below the head that this device does not hold is a rewrite',
        () async {
      final op = await _mint(author, authorSeq: 2, advance: false);
      final verdict = chainVerdict(
        header: op.header,
        envelope: op.envelope,
        head: (authorSeq: 5, envelopeHash: _someHash(0x33)),
      );
      expect(verdict.rejection!.reason, SyncRejectionReason.authorChainRewrite);
    });

    test('the same op id at a different position is a divergent duplicate',
        () async {
      // F13: deduping by op id is what makes a retry safe, and it must not
      // become the thing that hides a substitution.
      final op = await _mint(author, authorSeq: 4, advance: false);
      final verdict = chainVerdict(
        header: op.header,
        envelope: op.envelope,
        head: (authorSeq: 3, envelopeHash: op.header.prevAuthorHash),
        storedUnderOpId: (authorSeq: 2, envelope: op.envelope),
      );
      expect(verdict.rejection!.reason, SyncRejectionReason.duplicateOpIdDivergence);
      expect(verdict.alarm, IntegrityAlarmKind.duplicateOpIdDivergence);
    });

    test('the same op id at the same position with different bytes diverges',
        () async {
      const sharedOpId = '9c1f5b2a-0d3e-4a71-8b62-77c9e0f41a58';
      final held = await _mint(
        author,
        opId: sharedOpId,
        payloadJson: '{"collection":"held"}',
        advance: false,
      );
      final substitute = await _mint(
        author,
        opId: sharedOpId,
        payloadJson: '{"collection":"substituted"}',
        advance: false,
      );
      expect(held.envelope, isNot(substitute.envelope));
      expect(
        chainVerdict(
          header: substitute.header,
          envelope: substitute.envelope,
          storedUnderOpId: (authorSeq: 1, envelope: held.envelope),
          storedAtAuthorSeq: (authorSeq: 1, envelope: held.envelope),
        ).rejection!.reason,
        SyncRejectionReason.duplicateOpIdDivergence,
      );
    });

    test('the same op id, same position, same bytes is the honest re-serve',
        () async {
      final op = await _mint(author);
      expect(
        chainVerdict(
          header: op.header,
          envelope: op.envelope,
          head: (authorSeq: 1, envelopeHash: envelopeHash(op.envelope)),
          storedUnderOpId: (authorSeq: 1, envelope: op.envelope),
          storedAtAuthorSeq: (authorSeq: 1, envelope: op.envelope),
        ).outcome,
        ChainOutcome.idempotentSkip,
      );
    });

    group('the #555 verified floor', () {
      test('substitutes for an absent head, so floor + 1 is accepted', () async {
        final floorHash = _someHash(0x44);
        author.nextAuthorSeq = 11;
        author.lastEnvelopeHash = floorHash;
        final op = await _mint(author);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            verifiedFloor: (seq: 10, envelopeHash: floorHash),
          ).outcome,
          ChainOutcome.accept,
        );
      });

      test('does not let a supplied floor fall into the zero-hash branch',
          () async {
        // The post-prune bootstrap hazard: with a floor at 10 and no rows for
        // this author, an op 1 with the zero hash is not "a chain starting here".
        final op = await _mint(author);
        expect(op.header.authorSeq, 1);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            verifiedFloor: (seq: 10, envelopeHash: _someHash(0x44)),
          ).rejection!.reason,
          SyncRejectionReason.authorChainRewrite,
        );
      });

      test('wins above a derived head, so a mid-chain hole is bridgeable',
          () async {
        // The one deliberate change #555 makes to shipped verification logic.
        // Entity-level pruning punches holes *inside* an author's chain, so a
        // device may hold positions 1-2 and have to verify position 41 across
        // attested ones; a rule that always preferred the derived head could never
        // get there. Sound because the caller walks the floor contiguously forward
        // from the real head — there is no gap in it to hide anything in.
        final held = await _mint(author);
        final floorHash = _someHash(0x55);
        author.nextAuthorSeq = 41;
        author.lastEnvelopeHash = floorHash;
        final survivor = await _mint(author);
        expect(
          chainVerdict(
            header: survivor.header,
            envelope: survivor.envelope,
            head: (authorSeq: 1, envelopeHash: envelopeHash(held.envelope)),
            verifiedFloor: (seq: 40, envelopeHash: floorHash),
          ).outcome,
          ChainOutcome.accept,
        );
      });

      test('loses at or below the derived head, where the log is better evidence',
          () async {
        final first = await _mint(author);
        final second = await _mint(author);
        expect(
          chainVerdict(
            header: second.header,
            envelope: second.envelope,
            head: (authorSeq: 1, envelopeHash: envelopeHash(first.envelope)),
            // A floor *behind* the log says nothing the log does not already say.
            verifiedFloor: (seq: 1, envelopeHash: _someHash(0x55)),
          ).outcome,
          ChainOutcome.accept,
        );
      });

      test('a position beyond the bridge is still a gap', () async {
        // Partial bridge: the floor reaches 40 and the op claims 45, so five
        // positions are accounted for by nobody. Attestations widen what is
        // verified, never what is assumed.
        author.nextAuthorSeq = 45;
        author.lastEnvelopeHash = _someHash(0x66);
        final op = await _mint(author);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            verifiedFloor: (seq: 40, envelopeHash: _someHash(0x55)),
          ).rejection!.reason,
          SyncRejectionReason.authorChainGap,
        );
      });

      test('an op naming the wrong hash at the bridged position is refused',
          () async {
        author.nextAuthorSeq = 41;
        author.lastEnvelopeHash = _someHash(0x66);
        final op = await _mint(author);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            verifiedFloor: (seq: 40, envelopeHash: _someHash(0x55)),
          ).rejection!.reason,
          SyncRejectionReason.prevAuthorHashMismatch,
        );
      });
    });

    group('the #555 attestation at an arriving position', () {
      test('a pruned original re-served is superseded, and accuses nobody',
          () async {
        final op = await _mint(author);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            head: (authorSeq: 5, envelopeHash: _someHash(0x77)),
            storedAttestation: (
              authorSeq: op.header.authorSeq,
              envelopeHash: envelopeHash(op.envelope),
            ),
          ).outcome,
          ChainOutcome.supersededByPrune,
        );
      });

      test('different bytes at an attested position stand accused', () async {
        // The forged-claimant shape: a server offering something *other* than what
        // the compactor attested at a position it claimed to have removed. Both
        // signatures are real, so this is an accusation rather than a bare refusal.
        final op = await _mint(author);
        final verdict = chainVerdict(
          header: op.header,
          envelope: op.envelope,
          head: (authorSeq: 5, envelopeHash: _someHash(0x77)),
          storedAttestation: (
            authorSeq: op.header.authorSeq,
            envelopeHash: _someHash(0x88),
          ),
        );
        expect(verdict.rejection!.reason, SyncRejectionReason.pruneAttestationDivergence);
        expect(verdict.alarm, IntegrityAlarmKind.pruneAttestationDivergence);
      });

      test('a stored op at the position outranks any attestation about it',
          () async {
        // Evidence beats an attestation *about* evidence: the honest re-serve is
        // still an idempotent skip, and a substitution is still a rewrite.
        final op = await _mint(author);
        expect(
          chainVerdict(
            header: op.header,
            envelope: op.envelope,
            head: (authorSeq: 5, envelopeHash: _someHash(0x77)),
            storedAtAuthorSeq: (authorSeq: op.header.authorSeq, envelope: op.envelope),
            storedAttestation: (
              authorSeq: op.header.authorSeq,
              envelopeHash: _someHash(0x88),
            ),
          ).outcome,
          ChainOutcome.idempotentSkip,
        );
      });
    });
  });

  group('the release scan', () {
    test('a deep reorder heals in one flat loop, with no nested scans', () async {
      // 50 ops served newest-first: every one but the last is a gap on arrival,
      // and the last unlocks all 49 of them. A scan that re-entered itself from
      // `_receive` would still converge — but it would raise the reordered alarm
      // once per nesting level, so the occurrence count is what pins the shape.
      //
      // Sized down from 200, where this was the second-slowest test in the
      // suite at 74% of the per-test budget on the Pi agent host (#440). The
      // cost is linear in the op count and the discriminating power is not:
      // occurrenceCount is 1 for a flat scan and N-1 for a nested one at every
      // N, so 49 separates them exactly as unambiguously as 199 did. What the
      // larger number bought was reassurance about depth, not detection.
      const opCount = 50;
      final workspace = await SimWorkspace.create();
      addTearDown(workspace.close);
      final author = await AuthorFixture.create(
        seed: Uint8List.fromList(List<int>.generate(32, (index) => index + 51)),
      );
      final session = await workspace.enrolFixture(author);
      // The register has to land first or every content op would stop at the
      // key lookup instead of reaching the chain rules.
      await workspace.a.sync();

      final entityId = preferenceEntityId(workspace.workspaceId, 'deep-reorder');
      final envelopes = <Uint8List>[];
      for (var index = 0; index < opCount; index++) {
        workspace.clock.advance(10);
        envelopes.add(await author.nextEnvelope(
          workspace.workspaceId,
          payloadJson: jsonEncode({
            'collection': _harnessCollection,
            'id': entityId,
            'fields': {
              'step': {'v': index},
            },
            'hlc': [workspace.clock.nowMs, 0, memberIdToHex(author.memberId)],
          }),
        ));
      }
      final appended = await session.postOps(workspace.workspaceId, envelopes);
      workspace.server.serveOrder = [
        for (final result in appended.reversed) result.seq,
      ];

      await workspace.a.sync();

      // Everything arrived, so everything applies: a hostile reorder must not
      // cost data that actually made it to the device.
      final entity = await workspace.a.registry
          .register(_harnessCollection)
          .readEntity(entityId);
      expect(entity, {'step': opCount - 1});
      expect(
        await workspace.a.client.quarantined(includeReleased: false),
        isEmpty,
        reason: 'every gap row should have been released',
      );

      final alarms = await workspace.a.client.integrityAlarms();
      final reordered = alarms.singleWhere(
        (alarm) => alarm.kind == IntegrityAlarmKind.authorStreamReordered.code,
      );
      expect(reordered.occurrenceCount, 1);
      expect(reordered.resolvedAt, isNull);
      final gap = alarms.singleWhere(
        (alarm) => alarm.kind == IntegrityAlarmKind.authorChainGap.code,
      );
      expect(gap.resolvedAt, isNotNull, reason: 'nothing is still missing');
      expect((await workspace.a.client.health()).alarmKinds, {
        IntegrityAlarmKind.authorStreamReordered.code,
      });
    });
  });

  group('the v3 to v4 migration', () {
    final receivedAt = DateTime.utc(2026, 7, 1, 9, 30);
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jeeves-migration-');
      file = File('${directory.path}/sync.sqlite');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    /// The v3 shapes of the two tables v4 alters, plus one row in each.
    ///
    /// Written as raw DDL on purpose: the point of the test is a device whose
    /// store predates this slice, and the only honest way to have one is to build
    /// the old schema rather than the current classes' idea of it. Timestamps are
    /// ISO-8601 text because that is what `store_date_time_values_as_text` makes
    /// every date in this store, v3 rows included.
    void writeV3Store({bool withDuplicateChainSlot = false}) {
      final database = raw.sqlite3.open(file.path);
      database
        ..execute('''
CREATE TABLE op_log (
  seq INTEGER NOT NULL,
  workspace_id TEXT NOT NULL,
  envelope BLOB NOT NULL,
  op_id TEXT NOT NULL,
  author_member_id TEXT NOT NULL,
  author_seq INTEGER NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, seq)
)''')
        ..execute('''
CREATE TABLE quarantined_ops (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  seq INTEGER,
  reason TEXT NOT NULL,
  detail TEXT NOT NULL,
  envelope BLOB NOT NULL,
  detected_at TEXT NOT NULL
)''')
        ..execute(
          'INSERT INTO op_log VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            7,
            _workspaceId,
            Uint8List.fromList([1, 2, 3]),
            'op-7',
            'member-1',
            4,
            receivedAt.toIso8601String(),
          ],
        );
      if (withDuplicateChainSlot) {
        // Legal under the v3 `(workspace_id, seq)` primary key: a server that
        // re-served member-1's position 4 under a second transport seq.
        database.execute(
          'INSERT INTO op_log VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            8,
            _workspaceId,
            Uint8List.fromList([1, 2, 3]),
            'op-7',
            'member-1',
            4,
            receivedAt.toIso8601String(),
          ],
        );
      }
      database
        ..execute(
          'INSERT INTO quarantined_ops (workspace_id, seq, reason, detail, '
          'envelope, detected_at) VALUES (?, ?, ?, ?, ?, ?)',
          [
            _workspaceId,
            9,
            'bad_signature',
            'nope',
            Uint8List.fromList([4]),
            receivedAt.toIso8601String(),
          ],
        )
        ..execute('PRAGMA user_version = 3')
        ..close();
    }

    test('keeps every row and backfills applied_at from received_at', () async {
      writeV3Store();
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);

      final logged = await database.select(database.opLog).getSingle();
      expect(logged.seq, 7);
      expect(logged.authorSeq, 4);
      expect(logged.envelope, Uint8List.fromList([1, 2, 3]));
      expect(logged.receivedAt, receivedAt);
      // Everything logged before v4 was logged after a successful apply, so the
      // backfill is exact: leaving it null would say "never applied".
      expect(logged.appliedAt, logged.receivedAt);
      expect(logged.refusedReason, isNull);

      final refused = await database.select(database.quarantinedOps).getSingle();
      expect(refused.reason, 'bad_signature');
      expect(refused.releasedAt, isNull);
      expect(refused.authorMemberId, isNull);
      expect(refused.authorSeq, isNull);

      expect(await database.select(database.integrityAlarms).get(), isEmpty);
    });

    test('creates the chain-slot constraint as a constraint', () async {
      writeV3Store();
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);
      // One slot of an author's chain holds one op. Silent corruption of the
      // evidence the verdict is derived from is the thing this rules out.
      await expectLater(
        database.into(database.opLog).insert(
              OpLogCompanion.insert(
                seq: 8,
                workspaceId: _workspaceId,
                envelope: Uint8List.fromList([9]),
                opId: 'op-8',
                authorMemberId: 'member-1',
                authorSeq: 4,
                receivedAt: receivedAt,
              ),
            ),
        // Matched specifically: `anything` would also be satisfied by a missing
        // column or a closed database, so the assertion would still pass on a
        // store where the constraint had quietly stopped existing.
        throwsA(
          isA<raw.SqliteException>().having(
            (exception) => exception.message,
            'message',
            contains('UNIQUE'),
          ),
        ),
      );
    });

    test('refuses a store whose chain slots already collide, naming the recovery',
        () async {
      writeV3Store(withDuplicateChainSlot: true);
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);
      // Failing loud is the decision, not an oversight: the duplicate row is the
      // evidence that the server re-served a spent slot, so de-duplicating to let
      // the index through would destroy the thing worth keeping. What the message
      // owes the reader is the invariant and a way out.
      await expectLater(
        database.select(database.opLog).get(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('one op per (workspace, author, author_seq) chain slot'),
              contains('delete and recreate this sync store'),
            ),
          ),
        ),
      );
    });
  });

  group('the v5 to v6 migration', () {
    final detectedAt = DateTime.utc(2026, 7, 2, 11);
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('jeeves-alarm-migration-');
      file = File('${directory.path}/sync.sqlite');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    /// The v5 shape of the one table v6 constrains, plus the rows asked for.
    ///
    /// `integrity_alarms` is what v6 constrains, so its rows are what the leg
    /// asserts on. `quarantined_ops` (in its v5 shape — the v4 author/release
    /// columns already added) is created empty because opening this store at the
    /// current schema runs *every* later migration step, and v9 adds a column to
    /// it (#620): a real v5 store always holds this table, so the fixture must
    /// too, or the upgrade fails on a table only this partial fixture omitted.
    void writeV5Alarms(List<String?> authorMemberIds) {
      final database = raw.sqlite3.open(file.path);
      database.execute('''
CREATE TABLE integrity_alarms (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  author_member_id TEXT,
  detail TEXT NOT NULL,
  quarantine_op_row_id INTEGER,
  occurrence_count INTEGER NOT NULL,
  first_detected_at TEXT NOT NULL,
  last_detected_at TEXT NOT NULL,
  resolved_at TEXT
)''');
      database.execute('''
CREATE TABLE quarantined_ops (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  seq INTEGER,
  reason TEXT NOT NULL,
  detail TEXT NOT NULL,
  envelope BLOB NOT NULL,
  detected_at TEXT NOT NULL,
  author_member_id TEXT,
  author_seq INTEGER,
  released_at TEXT
)''');
      for (final authorMemberId in authorMemberIds) {
        database.execute(
          'INSERT INTO integrity_alarms (workspace_id, kind, author_member_id, '
          'detail, occurrence_count, first_detected_at, last_detected_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            _workspaceId,
            'chain_gap',
            authorMemberId,
            'nope',
            1,
            detectedAt.toIso8601String(),
            detectedAt.toIso8601String(),
          ],
        );
      }
      database
        ..execute('PRAGMA user_version = 5')
        ..close();
    }

    test('makes the documented alarm upsert key a constraint', () async {
      writeV5Alarms(['member-1']);
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);

      await expectLater(
        database.into(database.integrityAlarms).insert(
              IntegrityAlarmsCompanion.insert(
                workspaceId: _workspaceId,
                kind: 'chain_gap',
                authorMemberId: const Value('member-1'),
                detail: 'again',
                occurrenceCount: 1,
                firstDetectedAt: detectedAt,
                lastDetectedAt: detectedAt,
              ),
            ),
        throwsA(
          isA<raw.SqliteException>().having(
            (exception) => exception.message,
            'message',
            contains('UNIQUE'),
          ),
        ),
      );
    });

    test('leaves server-only alarms to the select path', () async {
      // SQLite reads distinct NULLs as distinct, so the index cannot constrain
      // the accusations that name no author. The pre-flight has to agree with the
      // index about that or it would refuse a store the index would accept.
      writeV5Alarms([null, null]);
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);

      expect((await database.select(database.integrityAlarms).get()).length, 2);
    });

    test('refuses a store whose alarm keys already collide', () async {
      writeV5Alarms(['member-1', 'member-1']);
      final database = SyncDatabase(NativeDatabase(file));
      addTearDown(database.close);

      await expectLater(
        database.select(database.integrityAlarms).get(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('one standing accusation per (workspace, kind, author)'),
              contains('delete and recreate this sync store'),
            ),
          ),
        ),
      );
    });
  });
}
