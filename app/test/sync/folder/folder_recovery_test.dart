/// How the folder plugin recovers from what a crash, a file syncer or another app
/// leaves behind: a torn tail of its own, a gap, a rolled-back own file, a record
/// it refuses, and the age bound on a segment.
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/folder/segment_format.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'folder_harness.dart';

const String _userId = 'folder-recovery-user';
const List<String> _outcomeIds = [
  '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f',
  '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70',
  '5b4f3e60-7c8d-4eaf-9012-3c4d5e6f7081',
];

Future<({Directory directory, FolderDevice a, FolderDevice b})> _pair(
    {int? rollBytes, Duration? rollAge}) async {
  final directory = Directory.systemTemp.createTempSync('folder-recovery-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final a = await FolderDevice.open('a', directory);
  final b = await FolderDevice.open('b', directory);
  addTearDown(a.close);
  addTearDown(b.close);
  await a.bind();
  await b.bind();
  await a.pairWith(b);
  await b.pairWith(a);
  await a.attach(rollBytes: rollBytes, rollAge: rollAge);
  await b.attach();
  return (directory: directory, a: a, b: b);
}

Future<void> _insert(FolderDevice device, int index, {int stepMs = 1000}) async {
  device.device.wall.advance(stepMs);
  await device.device.domain.todoDao
      .insertOutcome(id: _outcomeIds[index], title: 'Outcome $index', userId: _userId);
  await device.host.deliverAll();
}

Future<List<IntegrityAlarmRow>> _open(FolderDevice device) async {
  final rows = await device.device.sync.select(device.device.sync.integrityAlarms).get();
  return [
    for (final row in rows)
      if (row.resolvedAt == null) row,
  ];
}

Future<FolderSyncBindingRow> _binding(FolderDevice device) =>
    device.device.sync.select(device.device.sync.folderSyncBindings).getSingle();

Future<int> _pendingCount(FolderDevice device) async =>
    (await device.device.sync.select(device.device.sync.folderPendingAppends).get()).length;

/// Put the device back where a crash between "bytes written" and "length recorded"
/// leaves it: the last record is still queued and the recorded length is short of it.
Future<({File segment, Uint8List whole, int tailStart})> _crashBeforeRecordingLastRecord(
  Directory directory,
  FolderDevice a,
) async {
  final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
  final whole = segment.readAsBytesSync();
  final records = readRecords(whole);
  expect(records.length, greaterThanOrEqualTo(2));
  final tailStart = records[records.length - 2].endOffset;
  final tail = Uint8List.sublistView(whole, tailStart);
  final header = headerOf(records.last.envelope);
  await a.device.sync.into(a.device.sync.folderPendingAppends).insert(
        FolderPendingAppendsCompanion.insert(
          folderId: a.folderId,
          opId: header.opId,
          authorSeq: header.authorSeq,
          record: tail,
        ),
      );
  await (a.device.sync.update(a.device.sync.folderSyncBindings))
      .write(FolderSyncBindingsCompanion(segmentLengthBytes: Value(tailStart)));
  return (segment: segment, whole: whole, tailStart: tailStart);
}

void main() {
  group('this device\'s own tail after a crash', () {
    test('a torn write is completed, not duplicated, and the peer converges', () async {
      final (:directory, :a, :b) = await _pair();
      await _insert(a, 0);
      await _insert(a, 1);
      final crashed = await _crashBeforeRecordingLastRecord(directory, a);
      crashed.segment.writeAsBytesSync(
          Uint8List.sublistView(crashed.whole, 0, crashed.tailStart + 5));

      await a.plugin!.scan();

      expect(crashed.segment.readAsBytesSync(), crashed.whole);
      expect((await _binding(a)).segmentLengthBytes, crashed.whole.length);
      expect(await _pendingCount(a), 0);
      expect(await _open(a), isEmpty);
      await b.plugin!.scan();
      expect(await b.device.domain.customSelect('SELECT id FROM todos').get(), hasLength(2));
    });

    test('a write that fully landed is recorded without a second copy', () async {
      final (:directory, :a, b: _) = await _pair();
      await _insert(a, 0);
      await _insert(a, 1);
      final crashed = await _crashBeforeRecordingLastRecord(directory, a);

      await a.plugin!.scan();

      expect(crashed.segment.readAsBytesSync(), crashed.whole);
      expect((await _binding(a)).segmentLengthBytes, crashed.whole.length);
      expect(await _pendingCount(a), 0);
    });

    test('bytes this device did not write raise author_chain_rewrite', () async {
      final (:directory, :a, b: _) = await _pair();
      await _insert(a, 0);
      await _insert(a, 1);
      final crashed = await _crashBeforeRecordingLastRecord(directory, a);
      final foreign = Uint8List.fromList(
          Uint8List.sublistView(crashed.whole, 0, crashed.tailStart + 5))
        ..[crashed.tailStart + 4] ^= 0xFF;
      crashed.segment.writeAsBytesSync(foreign);

      await a.plugin!.scan();

      expect((await _open(a)).map((row) => row.kind), ['author_chain_rewrite']);
      expect(crashed.segment.readAsBytesSync(), foreign, reason: 'nothing was appended');
      expect(await _pendingCount(a), 1);
    });

    test('a rolled-back own segment raises an alarm and stops writing', () async {
      final (:directory, :a, b: _) = await _pair();
      await _insert(a, 0);
      await _insert(a, 1);
      final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
      final whole = segment.readAsBytesSync();
      final records = readRecords(whole);
      expect(records.length, greaterThanOrEqualTo(2));
      final firstEnd = records.first.endOffset;
      final rolledBack = Uint8List.sublistView(whole, 0, firstEnd);
      segment.writeAsBytesSync(rolledBack);

      await _insert(a, 2);

      expect((await _open(a)).map((row) => row.kind), ['segment_rolled_back']);
      expect(segment.readAsBytesSync(), rolledBack, reason: 'nothing was written over it');
      expect(await _pendingCount(a), greaterThan(0));
    });
  });

  group('segments', () {
    test('roll at the age bound', () async {
      final (:directory, :a, b: _) = await _pair(rollAge: const Duration(hours: 1));
      await _insert(a, 0);
      await _insert(a, 1, stepMs: const Duration(hours: 2).inMilliseconds);
      final names = [
        for (final file in Directory('${directory.path}/ops/${a.memberId}').listSync())
          if (file is File && file.path.endsWith('.log')) file.uri.pathSegments.last,
      ]..sort();
      expect(names, containsAll(['000001.log', '000002.log']));
    });

    test('a gap raises author_chain_gap, and the alarm resolves when it fills', () async {
      final (:directory, :a, :b) = await _pair(rollBytes: 1);
      await _insert(a, 0);
      await _insert(a, 1);
      await _insert(a, 2);
      final first = File('${directory.path}/ops/${a.memberId}/000001.log');
      final whole = first.readAsBytesSync();
      expect(File('${directory.path}/ops/${a.memberId}/000002.log').existsSync(), isTrue);
      first.writeAsBytesSync(Uint8List.sublistView(whole, 0, 10));

      await b.plugin!.scan();
      expect((await _open(b)).map((row) => row.kind), ['author_chain_gap']);
      expect(await b.device.domain.customSelect('SELECT id FROM todos').get(), isEmpty);

      first.writeAsBytesSync(whole);
      await b.plugin!.scan();
      expect(await _open(b), isEmpty);
      expect(await b.device.domain.customSelect('SELECT id FROM todos').get(), hasLength(3));
    });
  });

  group('a chain-valid record the reader refuses', () {
    test('is quarantined once, the chain moves past it, and a re-read adds no row', () async {
      final (:directory, :a, :b) = await _pair();
      await _insert(a, 0);
      await b.plugin!.scan();
      final before = await b.device.sync.select(b.device.sync.folderPeers).getSingle();

      // A correctly signed, correctly chained record that names another folder.
      final binding = await _binding(a);
      final keys = (await a.keyStore.read(a.folderId))!;
      final signer = await EnvelopeSigner.fromSeed(keys.signSeed);
      final envelope = await signer.buildEnvelope(
        OpHeader(
          workspaceId: '11111111-2222-3333-4444-555555555555',
          opId: '66666666-7777-4888-9999-aaaaaaaaaaaa',
          authorMemberId: a.memberId,
          authorKeyId: signer.keyId,
          authorSeq: binding.nextAuthorSeq,
          prevAuthorHash: binding.lastEnvelopeHash == null
              ? null
              : Uint8List.fromList(binding.lastEnvelopeHash!),
        ),
        frameBody(Uint8List.fromList([0])),
      );
      final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
      segment.writeAsBytesSync(encodeRecord(envelope), mode: FileMode.append);

      await b.plugin!.scan();
      Future<int> quarantined() async =>
          (await b.device.sync.select(b.device.sync.quarantinedOps).get()).length;
      expect(await quarantined(), 1);
      expect(await _open(b), isEmpty);
      final after = await b.device.sync.select(b.device.sync.folderPeers).getSingle();
      expect(after.headAuthorSeq, binding.nextAuthorSeq);
      expect(after.cursorOffsetBytes, segment.lengthSync());

      // A crash before the cursor was saved: the cursor is back, the row is not.
      await (b.device.sync.update(b.device.sync.folderPeers)).write(FolderPeersCompanion(
        cursorSegment: Value(before.cursorSegment),
        cursorOffsetBytes: Value(before.cursorOffsetBytes),
        headAuthorSeq: Value(before.headAuthorSeq),
        headEnvelopeHash: Value(before.headEnvelopeHash),
      ));
      await b.plugin!.scan();
      expect(await quarantined(), 1);
      expect(
          (await b.device.sync.select(b.device.sync.folderPeers).getSingle()).headAuthorSeq,
          binding.nextAuthorSeq);
    });
  });
}
