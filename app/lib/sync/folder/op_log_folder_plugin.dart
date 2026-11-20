/// The op-log folder plugin: sync through per-member segment files in a folder.
///
/// A carrier and nothing more. Each device appends signed ops to its own segment
/// files under `ops/<member id>/` and reads the files of every device it has
/// paired with. The plugin never decides a value: what it reads is handed to
/// [SyncHost.applyRemote] with the author's clocks untouched, and what it writes
/// is what [SyncPlugin.deliver] gave it. It reaches the app only through those two.
///
/// Design: `docs/FOLDER_SYNC.md`.
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:uuid/uuid.dart';

import '../chain_verifier.dart';
import '../device_key_store.dart';
import '../envelope.dart';
import '../hlc.dart';
import '../host/change.dart';
import '../host/sync_host.dart';
import '../op_payload.dart';
import '../sync_database.dart';
import 'folder_codec.dart';
import 'folder_metadata.dart';
import 'folder_setup.dart';
import 'segment_folder.dart';
import 'segment_format.dart';

const String opLogFolderPluginId = 'op-log-folder';

/// How far an op clock may run ahead of this device's wall clock.
const int folderFutureSkewBoundMs = 5 * 60 * 1000;

const int _firstReadChunkBytes = 1024 * 1024;

class OpLogFolderPlugin implements SyncPlugin {
  OpLogFolderPlugin({
    required this.database,
    required this.folder,
    required this.keyStore,
    required this.folderId,
    required this.isEnrolled,
    required this.nowMs,
    this.rollBytes = segmentRollBytes,
    this.rollAge = segmentRollAge,
    this.scanInterval,
  });

  final SyncDatabase database;
  final SegmentFolder folder;
  final DeviceKeyStore keyStore;
  final String folderId;
  final EnrolmentCheck isEnrolled;
  final int Function() nowMs;
  final int rollBytes;
  final Duration rollAge;

  /// How often to look for other devices' changes while attached; null for never
  /// (a test drives [scan] itself).
  final Duration? scanInterval;

  @override
  String get id => opLogFolderPluginId;

  late SyncHost _host;
  late String _memberId;
  late String _memberIdHex;
  late EnvelopeSigner _signer;
  Timer? _timer;
  Future<void> _serial = Future<void>.value();
  DateTime? _lastScanAt;

  /// Set when the attachment stops. A delivery the host was already reading
  /// when sync was turned off must not write anything more.
  bool _stopped = false;
  final StreamController<PluginHealth> _health = StreamController<PluginHealth>.broadcast();

  @override
  Stream<PluginHealth> get health => _health.stream;

  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _serial.then((_) => body());
    _serial = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  // --- Lifecycle -------------------------------------------------------------

  @override
  Future<void> start(SyncHost host) async {
    if (await isEnrolled()) throw const FolderSyncRefusal(enrolledRefusalMessage);
    _host = host;
    final binding = await _binding();
    if (!binding.isActive) {
      throw const FolderSyncRefusal('Folder sync is turned off for this folder.');
    }
    final keys = await keyStore.read(folderId);
    if (keys == null || keys.memberId != binding.memberId) {
      throw const FolderSyncRefusal('This device has no key for this folder.');
    }
    _memberId = binding.memberId;
    _memberIdHex = memberIdToHex(_memberId);
    _signer = await EnvelopeSigner.fromSeed(keys.signSeed);
    await _locked(() async {
      // The enrolment check again, before the first write: enrolling can finish
      // while this device is starting, and a signed-in device writes nothing.
      await _refuseIfEnrolled();
      await _enqueueSnapshotOnce();
      await _appendPending();
      await _scanPeers();
    });
    final interval = scanInterval;
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) {
        unawaited(scan().catchError((Object error) {
          debugPrint('op-log folder: scan failed — $error');
        }));
      });
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _serial;
  }

  /// Look for other devices' changes now: at start, on app resume and on a timer.
  Future<void> scan() => _locked(() async {
        if (_stopped) return;
        await _refuseIfEnrolled();
        await _appendPending();
        await _scanPeers();
      });

  /// A device that has since signed in or been enrolled writes nothing more into
  /// the folder and reads nothing from it, however it came to be attached.
  Future<void> _refuseIfEnrolled() async {
    if (!await isEnrolled()) return;
    _timer?.cancel();
    _timer = null;
    throw const FolderSyncRefusal(enrolledRefusalMessage);
  }

  Future<FolderSyncBindingRow> _binding() async =>
      await (database.select(database.folderSyncBindings)
            ..where((row) => row.folderId.equals(folderId)))
          .getSingleOrNull() ??
      (throw const FolderSyncRefusal('This device is not set up in that folder.'));

  Future<void> _emitHealth() async {
    if (!_health.hasListener) return;
    final pendingCount = database.folderPendingAppends.id.count();
    final pending = await (database.selectOnly(database.folderPendingAppends)
          ..addColumns([pendingCount])
          ..where(database.folderPendingAppends.folderId.equals(folderId)))
        .map((row) => row.read(pendingCount) ?? 0)
        .getSingle();
    _health.add(PluginHealth(pendingChangeCount: pending, lastSyncedAt: _lastScanAt));
  }

  // --- Writing ---------------------------------------------------------------

  @override
  Future<int> deliver(List<SequencedChange> changes) async {
    if (changes.isEmpty) return 0;
    var acknowledged = 0;
    await _locked(() async {
      // Sync was turned off while the host was reading this batch: nothing is
      // written, and nothing is acknowledged, so the changes stay owed.
      if (_stopped) return;
      await _refuseIfEnrolled();
      await _enqueueDelivered(changes);
      try {
        await _appendPending();
      } on Object catch (error) {
        // The queue is the durable hand-off; the next scan appends it.
        debugPrint('op-log folder: append failed — $error');
      }
      await _emitHealth();
      acknowledged = changes.last.sequence;
    });
    return acknowledged;
  }

  Future<void> _enqueueDelivered(List<SequencedChange> changes) async {
    await database.transaction(() async {
      final state = await _AuthorState.load(this);
      for (final sequenced in changes) {
        if (sequenced.sequence <= state.lastEnqueuedSequence) continue;
        await _enqueue(
          state,
          sequenced.change,
          'change:$_memberId:${sequenced.sequence}',
        );
        state.lastEnqueuedSequence = sequenced.sequence;
      }
      await state.save(this);
    });
  }

  /// Turn the merged state into ops once per binding, in one transaction with the
  /// marker that says it was done.
  Future<void> _enqueueSnapshotOnce() async {
    if ((await _binding()).snapshotEnqueued) return;
    final snapshot = await _host.snapshot().toList();
    await database.transaction(() async {
      final state = await _AuthorState.load(this);
      if (state.snapshotEnqueued) return;
      for (final change in snapshot) {
        await _enqueue(
          state,
          change,
          'snapshot:$_memberId:${state.nextAuthorSeq}',
        );
      }
      state.snapshotEnqueued = true;
      await state.save(this);
    });
  }

  Future<void> _enqueue(_AuthorState state, Change change, String opName) async {
    // The op format carries entity ids as canonical UUIDs; a receiver refuses any
    // other, so one that would be refused is never signed into the folder.
    if (!isCanonicalUuid(change.entityId)) {
      debugPrint('op-log folder: skipped ${change.collection}/${change.entityId} — '
          'its id is not a canonical UUID');
      return;
    }
    final built = payloadForChange(
      change,
      memberIdHex: _memberIdHex,
      mintClock: _host.mintClock,
    );
    if (built == null) return;
    guardOpClassShape(built.payload, opClass: built.opClass);
    final header = OpHeader(
      workspaceId: folderId,
      opClass: built.opClass,
      opId: const Uuid().v5(folderId, opName),
      authorMemberId: _memberId,
      authorKeyId: _signer.keyId,
      authorSeq: state.nextAuthorSeq,
      prevAuthorHash: state.lastEnvelopeHash,
    );
    final envelope = await _signer.buildEnvelope(header, frameBody(built.payload.encode()));
    if (envelope.length > maxEnvelopeBytes) {
      // Every reader would treat it as never arriving; signing it would stall the
      // chain, and throwing would wedge delivery of everything behind it.
      debugPrint('op-log folder: skipped ${change.collection}/${change.entityId} — '
          'its op is larger than $maxEnvelopeBytes bytes');
      return;
    }
    await database.into(database.folderPendingAppends).insert(
          FolderPendingAppendsCompanion.insert(
            folderId: folderId,
            opId: header.opId,
            authorSeq: header.authorSeq,
            record: encodeRecord(envelope),
          ),
        );
    state.nextAuthorSeq += 1;
    state.lastEnvelopeHash = envelopeHash(envelope);
  }

  /// Write pending records to the segment file, in order, recording the length
  /// after each. Stops, with an alarm, when the file is not what this device left.
  Future<void> _appendPending() async {
    while (true) {
      final pending = await (database.select(database.folderPendingAppends)
            ..where((row) => row.folderId.equals(folderId))
            ..orderBy([(row) => OrderingTerm(expression: row.id)])
            ..limit(1))
          .getSingleOrNull();
      if (pending == null) return;
      var binding = await _binding();
      final now = nowMs();
      final record = Uint8List.fromList(pending.record);
      var segmentNumber = binding.segmentNumber;
      var path = '$opsDirectoryName/$_memberId/${segmentFileName(segmentNumber)}';
      var recorded = binding.segmentLengthBytes;
      var actual = await folder.length(path) ?? 0;

      // The tail of the current segment is reconciled before anything else. A
      // crash between the write and the transaction that records the length
      // leaves bytes this device wrote but has not recorded; they belong to the
      // record being appended, so that record is finished here. Rolling first
      // would write the same record a second time, in the next segment.
      var tail = await _reconcileTail(path, segmentNumber, recorded, actual, record);
      if (tail == null) return;

      // A segment is rolled only when it holds exactly what this device
      // recorded: a segment with an unreconciled tail is finished first.
      if (!tail.complete && actual == recorded && recorded > 0 &&
          (recorded >= rollBytes ||
              (binding.segmentStartedAtMs != null &&
                  now - binding.segmentStartedAtMs! >= rollAge.inMilliseconds))) {
        segmentNumber = binding.segmentNumber + 1;
        path = '$opsDirectoryName/$_memberId/${segmentFileName(segmentNumber)}';
        await (database.update(database.folderSyncBindings)
              ..where((row) => row.folderId.equals(folderId)))
            .write(FolderSyncBindingsCompanion(
          segmentNumber: Value(segmentNumber),
          segmentLengthBytes: const Value(0),
          segmentStartedAtMs: const Value(null),
        ));
        binding = await _binding();
        recorded = binding.segmentLengthBytes;
        actual = await folder.length(path) ?? 0;
        tail = await _reconcileTail(path, segmentNumber, recorded, actual, record);
        if (tail == null) return;
      }

      if (!tail.complete) {
        await folder.append(path, Uint8List.sublistView(record, tail.offset));
      }
      await database.transaction(() async {
        await (database.update(database.folderSyncBindings)
              ..where((row) => row.folderId.equals(folderId)))
            .write(FolderSyncBindingsCompanion(
          segmentLengthBytes: Value(recorded + record.length),
          segmentStartedAtMs: Value(binding.segmentStartedAtMs ?? now),
        ));
        await (database.delete(database.folderPendingAppends)
              ..where((row) => row.id.equals(pending.id)))
            .go();
      });
    }
  }

  /// What the bytes past the recorded length say about the record being
  /// appended.
  ///
  /// [offset] is where the record has to be written from; a record that is
  /// already complete on disk has [complete] set and is not written again.
  Future<_Tail?> _reconcileTail(
    String path,
    int segmentNumber,
    int recorded,
    int actual,
    Uint8List record,
  ) async {
    if (actual < recorded) {
      await _raiseAlarm(
        IntegrityAlarmKind.segmentRolledBack,
        authorMemberId: _memberId,
        detail: 'This device wrote $recorded bytes to ${segmentFileName(segmentNumber)} '
            'but the file now holds $actual.',
      );
      return null;
    }
    await _resolveAlarm(IntegrityAlarmKind.segmentRolledBack, _memberId);
    if (actual == recorded) return const _Tail.appendAt(0);
    // A torn write from a crash: whatever is past the recorded length must be
    // the start (or all) of this very record.
    final extra = actual - recorded;
    final present = extra < record.length ? extra : record.length;
    final onDisk = await folder.read(path, offset: recorded, maxBytes: present);
    if (!sameBytes(onDisk, Uint8List.sublistView(record, 0, present))) {
      await _raiseAlarm(
        IntegrityAlarmKind.authorChainRewrite,
        authorMemberId: _memberId,
        detail: 'The file ${segmentFileName(segmentNumber)} holds bytes this '
            'device did not write.',
      );
      return null;
    }
    if (extra > record.length) {
      await _raiseAlarm(
        IntegrityAlarmKind.authorChainRewrite,
        authorMemberId: _memberId,
        detail: 'The file ${segmentFileName(segmentNumber)} holds bytes after '
            'the last record this device wrote.',
      );
      return null;
    }
    if (extra == record.length) return const _Tail.complete();
    return _Tail.appendAt(extra);
  }

  // --- Reading ---------------------------------------------------------------

  Future<void> _scanPeers() async {
    final peers = await (database.select(database.folderPeers)
          ..where((row) => row.folderId.equals(folderId)))
        .get();
    var everyPeerRead = true;
    for (final peer in peers) {
      try {
        await _scanPeer(peer);
      } on Object catch (error) {
        everyPeerRead = false;
        debugPrint('op-log folder: reading ${peer.memberId} failed — $error');
      }
    }
    // A scan that could not read a peer is not a success: the last-synced time
    // stays where it was, so a folder that stops delivering shows as stale.
    if (everyPeerRead) {
      _lastScanAt = DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true);
    }
    await _emitHealth();
  }

  Future<void> _scanPeer(FolderPeerRow peer) async {
    final memberId = peer.memberId;
    final publicKey = Uint8List.fromList(peer.signPublicKey);
    var committedSegment = peer.cursorSegment;
    var committedOffset = peer.cursorOffsetBytes;
    var headSeq = peer.headAuthorSeq;
    var headHash = peer.headEnvelopeHash == null
        ? null
        : Uint8List.fromList(peer.headEnvelopeHash!);
    var frameHash = peer.cursorFrameHash == null
        ? null
        : Uint8List.fromList(peer.cursorFrameHash!);

    final segmentLength = await folder.length(
        '$opsDirectoryName/$memberId/${segmentFileName(committedSegment)}');
    if (committedOffset > 0 && (segmentLength == null || segmentLength < committedOffset)) {
      await _raiseAlarm(
        IntegrityAlarmKind.segmentRolledBack,
        authorMemberId: memberId,
        detail: '${peer.deviceLabel}\'s ${segmentFileName(committedSegment)} is shorter '
            'than the part already read.',
      );
      return;
    }
    if (committedOffset > 0 && !await _headStillHolds(peer, frameHash ?? headHash)) {
      await _raiseAlarm(
        IntegrityAlarmKind.segmentRolledBack,
        authorMemberId: memberId,
        detail: '${peer.deviceLabel}\'s ${segmentFileName(committedSegment)} no longer '
            'holds what was already read.',
      );
      return;
    }
    await _resolveAlarm(IntegrityAlarmKind.segmentRolledBack, memberId);

    var readSegment = committedSegment;
    var readOffset = committedOffset;
    var halted = false;
    var chained = 0;
    final accepted = <Change>[];
    final alarmsToRaise = <({IntegrityAlarmKind kind, String detail})>[];

    while (!halted) {
      final path = '$opsDirectoryName/$memberId/${segmentFileName(readSegment)}';
      final length = await folder.length(path);
      var records = const <SegmentRecord>[];
      if (length != null && length > readOffset) {
        var bytes = await folder.read(path,
            offset: readOffset,
            maxBytes: (length - readOffset) < _firstReadChunkBytes
                ? length - readOffset
                : _firstReadChunkBytes);
        records = readRecords(bytes, startOffset: readOffset);
        if (records.isEmpty && length - readOffset > bytes.length) {
          final wanted = length - readOffset;
          bytes = await folder.read(path,
              offset: readOffset,
              maxBytes: wanted < maxEnvelopeBytes + 16 ? wanted : maxEnvelopeBytes + 16);
          records = readRecords(bytes, startOffset: readOffset);
        }
      }
      if (records.isEmpty) {
        // Nothing complete here. If a later segment exists, continue there; its
        // first record's chain link says whether anything is missing.
        final next = readSegment + 1;
        if (next <= 999999 &&
            await folder.length('$opsDirectoryName/$memberId/${segmentFileName(next)}') != null) {
          readSegment = next;
          readOffset = 0;
          continue;
        }
        // The next segment is absent. If a later one has arrived, the file
        // syncer delivered out of order: say so, and stay on the verified prefix.
        if (await _laterSegmentExists(memberId, readSegment)) {
          alarmsToRaise.add((
            kind: IntegrityAlarmKind.authorChainGap,
            detail: '${peer.deviceLabel}\'s ${segmentFileName(next)} has not arrived, '
                'but a later segment has.',
          ));
          halted = true;
        }
        break;
      }
      for (final record in records) {
        final outcome = await _judge(record, peer, publicKey, headSeq, headHash);
        if (outcome.alarm != null) {
          alarmsToRaise.add((kind: outcome.alarm!, detail: outcome.detail));
          halted = true;
          break;
        }
        if (outcome.change != null) accepted.add(outcome.change!);
        if (outcome.accepted) {
          chained += 1;
          headSeq = outcome.authorSeq!;
          headHash = envelopeHash(record.envelope);
        }
        frameHash = envelopeHash(record.envelope);
        committedSegment = readSegment;
        committedOffset = record.endOffset;
        readOffset = record.endOffset;
      }
    }

    if (accepted.isNotEmpty) await _host.applyRemote(id, accepted);
    await (database.update(database.folderPeers)
          ..where((row) => row.folderId.equals(folderId) & row.memberId.equals(memberId)))
        .write(FolderPeersCompanion(
      cursorSegment: Value(committedSegment),
      cursorOffsetBytes: Value(committedOffset),
      headAuthorSeq: Value(headSeq),
      headEnvelopeHash: Value(headHash),
      cursorFrameHash: Value(frameHash),
    ));
    for (final alarm in alarmsToRaise) {
      await _raiseAlarm(alarm.kind, authorMemberId: memberId, detail: alarm.detail);
    }
    // The gap alarm stands until a record that chains proves the gap filled: a
    // scan that reads nothing new has not seen the missing record arrive.
    if (!halted && chained > 0) {
      await _resolveAlarm(IntegrityAlarmKind.authorChainGap, memberId);
    }
  }

  Future<bool> _laterSegmentExists(String memberId, int segment) async {
    final names = await folder.listFiles('$opsDirectoryName/$memberId');
    for (final name in names) {
      final match = RegExp(r'^(\d{6})\.log$').firstMatch(name);
      if (match != null && int.parse(match.group(1)!) > segment + 1) return true;
    }
    return false;
  }

  /// With a rollback alarm standing, the file must again hold the record the
  /// cursor ended on before the reader trusts it. Without one, a cheap length check
  /// has already been done and this reads nothing.
  Future<bool> _headStillHolds(FolderPeerRow peer, Uint8List? frameHash) async {
    final standing = await (database.select(database.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(folderId) &
              row.kind.equals(IntegrityAlarmKind.segmentRolledBack.code) &
              row.authorMemberId.equals(peer.memberId) &
              row.resolvedAt.isNull()))
        .get();
    if (standing.isEmpty) return true;
    final path = '$opsDirectoryName/${peer.memberId}/${segmentFileName(peer.cursorSegment)}';
    final bytes = await folder.read(path, offset: 0, maxBytes: peer.cursorOffsetBytes);
    for (final record in readRecords(bytes)) {
      if (record.endOffset == peer.cursorOffsetBytes) {
        return frameHash != null && sameBytes(envelopeHash(record.envelope), frameHash);
      }
    }
    return false;
  }

  /// Verify one record. Returns either an alarm (the author's stream stops here,
  /// cursor unmoved), a quarantine-and-skip, or an accepted change.
  Future<_Judgement> _judge(
    SegmentRecord record,
    FolderPeerRow peer,
    Uint8List publicKey,
    int headSeq,
    Uint8List? headHash,
  ) async {
    final envelope = record.envelope;
    final OpHeader header;
    try {
      header = OpHeader.parse(envelope);
    } on SyncRejection catch (rejection) {
      await _quarantine(peer.memberId, null, rejection, envelope);
      return const _Judgement.skip();
    } on Object catch (error) {
      await _quarantine(
        peer.memberId,
        null,
        SyncRejection(SyncRejectionReason.malformedPayload, '$error'),
        envelope,
      );
      return const _Judgement.skip();
    }
    if (header.authorMemberId != peer.memberId ||
        !sameBytes(header.authorKeyId, deriveKeyId(publicKey))) {
      return _Judgement.alarm(
        IntegrityAlarmKind.signatureInvalid,
        'A record in ${peer.deviceLabel}\'s files names a different author or key.',
      );
    }
    try {
      await verifyEnvelope(envelope, publicKey);
    } on SyncRejection {
      return _Judgement.alarm(
        IntegrityAlarmKind.signatureInvalid,
        'A record in ${peer.deviceLabel}\'s files is not signed by the key you paired.',
      );
    }
    final verdict = chainVerdict(
      header: header,
      envelope: envelope,
      head: headSeq == 0 || headHash == null
          ? null
          : (authorSeq: headSeq, envelopeHash: headHash),
    );
    if (verdict.isRefusal) {
      return _Judgement.alarm(verdict.alarm!, verdict.rejection!.message);
    }
    if (verdict.outcome != ChainOutcome.accept) return const _Judgement.skip();

    try {
      final change = _changeOf(header, envelope);
      return _Judgement.accept(header.authorSeq, change);
    } on SyncRejection catch (rejection) {
      await _quarantine(peer.memberId, header.authorSeq, rejection, envelope);
      // Chain-valid but refused: the chain still advances past it.
      return _Judgement.refusedButChained(header.authorSeq);
    }
  }

  Change _changeOf(OpHeader header, Uint8List envelope) {
    if (header.suite != suitePlaintextV1 || header.keyEpoch != 0) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedSuite,
        'folder ops are plaintext at epoch 0; got suite ${header.suite} epoch ${header.keyEpoch}',
      );
    }
    if (header.opClass != opClassContent && header.opClass != opClassCompaction) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedOpClass,
        'folder ops are content or compaction-shaped; got class ${header.opClass}',
      );
    }
    if (header.workspaceId != folderId) {
      throw const SyncRejection(
        SyncRejectionReason.workspaceMismatch,
        'record names another folder',
      );
    }
    final parts = splitEnvelope(envelope);
    final payload = OpPayload.decode(parseBody(parts.body));
    guardOpClassShape(payload, opClass: header.opClass);
    if (payload.hlc.memberIdHex != memberIdToHex(header.authorMemberId)) {
      throw SyncRejection(
        SyncRejectionReason.hlcMemberIsNotAuthor,
        'op clock member ${payload.hlc.memberIdHex} is not the author',
      );
    }
    if (payload.hlc.wallMs > nowMs() + folderFutureSkewBoundMs) {
      throw SyncRejection(
        SyncRejectionReason.hlcInTheFuture,
        'op wall_ms ${payload.hlc.wallMs} is beyond the skew bound',
      );
    }
    // Every clock the merge uses is bounded, not only the op's own: a field or
    // tombstone clock far ahead would win last-writer-wins until wall time caught up.
    final mergeClocks = [
      for (final write in payload.fields.values)
        if (write.hlc != null) write.hlc!,
      if (payload.tombstoneHlc != null) payload.tombstoneHlc!,
    ];
    for (final clock in mergeClocks) {
      if (clock.wallMs > nowMs() + folderFutureSkewBoundMs) {
        throw SyncRejection(
          SyncRejectionReason.hlcInTheFuture,
          'clock wall_ms ${clock.wallMs} is beyond the skew bound',
        );
      }
    }
    return payload.toChange();
  }

  Future<void> _quarantine(
    String authorMemberId,
    int? authorSeq,
    SyncRejection rejection,
    Uint8List envelope,
  ) async {
    final already = await (database.select(database.quarantinedOps)
          ..where((row) =>
              row.workspaceId.equals(folderId) &
              row.authorMemberId.equals(authorMemberId) &
              row.envelope.equals(envelope))
          ..limit(1))
        .get();
    if (already.isNotEmpty) return;
    await database.into(database.quarantinedOps).insert(
          QuarantinedOpsCompanion.insert(
            workspaceId: folderId,
            reason: rejection.reason.code,
            detail: rejection.message,
            envelope: envelope,
            detectedAt: DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true),
            authorMemberId: Value(authorMemberId),
            authorSeq: Value(authorSeq),
          ),
        );
  }

  // --- Alarms ----------------------------------------------------------------

  Future<void> _raiseAlarm(
    IntegrityAlarmKind kind, {
    required String authorMemberId,
    required String detail,
  }) async {
    final now = DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true);
    final existing = await (database.select(database.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(folderId) &
              row.kind.equals(kind.code) &
              row.authorMemberId.equals(authorMemberId))
          ..limit(1))
        .get();
    if (existing.isNotEmpty) {
      final alarm = existing.first;
      await (database.update(database.integrityAlarms)
            ..where((row) => row.id.equals(alarm.id)))
          .write(IntegrityAlarmsCompanion(
        detail: Value(detail),
        occurrenceCount: Value(alarm.occurrenceCount + 1),
        lastDetectedAt: Value(now),
        resolvedAt: const Value(null),
      ));
      return;
    }
    await database.into(database.integrityAlarms).insert(
          IntegrityAlarmsCompanion.insert(
            workspaceId: folderId,
            kind: kind.code,
            authorMemberId: Value(authorMemberId),
            detail: detail,
            occurrenceCount: 1,
            firstDetectedAt: now,
            lastDetectedAt: now,
          ),
        );
  }

  Future<void> _resolveAlarm(IntegrityAlarmKind kind, String authorMemberId) async {
    await (database.update(database.integrityAlarms)
          ..where((row) =>
              row.workspaceId.equals(folderId) &
              row.kind.equals(kind.code) &
              row.authorMemberId.equals(authorMemberId) &
              row.resolvedAt.isNull()))
        .write(IntegrityAlarmsCompanion(
      resolvedAt: Value(DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true)),
    ));
  }
}

/// What the bytes past the recorded length of a segment say about the record
/// being appended to it.
class _Tail {
  const _Tail.appendAt(this.offset) : complete = false;

  /// The record is already whole on disk: it is not written again.
  const _Tail.complete() : offset = 0, complete = true;

  /// Where the record has to be written from.
  final int offset;
  final bool complete;
}

class _Judgement {
  const _Judgement.skip()
      : alarm = null,
        detail = '',
        change = null,
        authorSeq = null,
        accepted = false;

  const _Judgement.alarm(IntegrityAlarmKind this.alarm, this.detail)
      : change = null,
        authorSeq = null,
        accepted = false;

  const _Judgement.accept(int this.authorSeq, Change this.change)
      : alarm = null,
        detail = '',
        accepted = true;

  const _Judgement.refusedButChained(int this.authorSeq)
      : alarm = null,
        detail = '',
        change = null,
        accepted = true;

  final IntegrityAlarmKind? alarm;
  final String detail;
  final Change? change;
  final int? authorSeq;

  /// The record extended the author's chain.
  final bool accepted;
}

/// This device's author state in the folder, read and written in one transaction.
class _AuthorState {
  _AuthorState._(this.nextAuthorSeq, this.lastEnvelopeHash, this.lastEnqueuedSequence,
      this.snapshotEnqueued);

  static Future<_AuthorState> load(OpLogFolderPlugin plugin) async {
    final row = await plugin._binding();
    return _AuthorState._(
      row.nextAuthorSeq,
      row.lastEnvelopeHash == null ? null : Uint8List.fromList(row.lastEnvelopeHash!),
      row.lastEnqueuedSequence,
      row.snapshotEnqueued,
    );
  }

  int nextAuthorSeq;
  Uint8List? lastEnvelopeHash;
  int lastEnqueuedSequence;
  bool snapshotEnqueued;

  Future<void> save(OpLogFolderPlugin plugin) async {
    await (plugin.database.update(plugin.database.folderSyncBindings)
          ..where((row) => row.folderId.equals(plugin.folderId)))
        .write(FolderSyncBindingsCompanion(
      nextAuthorSeq: Value(nextAuthorSeq),
      lastEnvelopeHash: Value(lastEnvelopeHash),
      lastEnqueuedSequence: Value(lastEnqueuedSequence),
      snapshotEnqueued: Value(snapshotEnqueued),
    ));
  }
}
