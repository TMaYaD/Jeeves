/// What the folder plugin refuses, and why: the folder's contents are untrusted
/// input, and a device that is signed in or enrolled never uses a folder.
@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/folder/folder_metadata.dart';
import 'package:jeeves/sync/folder/folder_setup.dart';
import 'package:jeeves/sync/folder/segment_folder.dart';
import 'package:jeeves/sync/folder/segment_format.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'folder_harness.dart';

const String _outcomeA = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _userId = 'folder-refusal-user';

Directory _tempFolder() {
  final directory = Directory.systemTemp.createTempSync('folder-refusal-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

Future<(FolderDevice, FolderDevice)> _unpairedPair(Directory directory) async {
  final a = await FolderDevice.open('a', directory);
  final b = await FolderDevice.open('b', directory);
  addTearDown(a.close);
  addTearDown(b.close);
  await a.bind();
  await b.bind();
  return (a, b);
}

void main() {
  group('an enrolled or signed-in device never uses a folder', () {
    test('it cannot bind, pair or attach', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.pairWith(b);

      a.enrolled = true;
      final other = _tempFolder();
      final enrolled = await FolderDevice.open('e', other);
      addTearDown(enrolled.close);
      enrolled.enrolled = true;
      await expectLater(enrolled.bind(), throwsA(isA<FolderSyncRefusal>()));
      await expectLater(a.pairWith(b), throwsA(isA<FolderSyncRefusal>()));
      await expectLater(a.attach(), throwsA(isA<FolderSyncRefusal>()));
      expect(Directory('${other.path}/ops').existsSync(), isFalse,
          reason: 'nothing was written to the folder');
    });
  });

  group('pairing', () {
    test('an unpaired member is left alone', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.attach();
      await b.attach();
      await b.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From B', userId: _userId);
      await b.host.deliverAll();
      await a.plugin!.scan();
      expect(await a.device.domain.customSelect('SELECT id FROM todos').get(), isEmpty);

      await a.pairWith(b);
      await a.plugin!.scan();
      expect(await a.device.domain.customSelect('SELECT id FROM todos').get(), hasLength(1));
    });

    test('a changed key is refused rather than trusted', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.pairWith(b);
      final path = '${directory.path}/ops/${b.memberId}/$memberFileName';
      final original = MemberFile.parse(File(path).readAsBytesSync());
      File(path).writeAsBytesSync(MemberFile(
        folderId: original.folderId,
        memberId: original.memberId,
        signPublicKey: Uint8List(32)..[0] = 1,
        deviceLabel: original.deviceLabel,
      ).encode());
      await expectLater(a.pairWith(b), throwsA(isA<FolderSyncRefusal>()));
    });

    test('a member directory that is not a canonical id is never offered or opened',
        () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      Directory('${directory.path}/ops/evil name').createSync();
      Directory('${directory.path}/ops/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE').createSync();
      final found = await a.setup.candidates(a.folderId);
      expect(found.map((candidate) => candidate.memberId), [b.memberId]);
      await expectLater(a.setup.pair(a.folderId, '../evil'), throwsA(isA<FolderSyncRefusal>()));
    });

    test("another folder's member cannot be paired", () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      final path = '${directory.path}/ops/${b.memberId}/$memberFileName';
      final original = MemberFile.parse(File(path).readAsBytesSync());
      File(path).writeAsBytesSync(MemberFile(
        folderId: '11111111-2222-3333-4444-555555555555',
        memberId: original.memberId,
        signPublicKey: original.signPublicKey,
        deviceLabel: original.deviceLabel,
      ).encode());
      await expectLater(a.pairWith(b), throwsA(isA<FolderSyncRefusal>()));
      expect((await a.setup.candidates(a.folderId)).single.problem, isNotNull);
    });
  });

  group('a record that does not verify', () {
    test('raises an alarm, applies nothing and leaves the cursor where it was', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.pairWith(b);
      await b.pairWith(a);
      await a.attach();
      await b.attach();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await a.host.deliverAll();

      final segment = File('${directory.path}/ops/${a.memberId}/000001.log');
      final first = readRecords(segment.readAsBytesSync()).first;
      final forged = Uint8List.fromList(first.envelope)..[headerLengthBytes + 6] ^= 0x55;
      segment.writeAsBytesSync(encodeRecord(forged));

      await b.plugin!.scan();
      expect(await b.device.domain.customSelect('SELECT id FROM todos').get(), isEmpty);
      final alarms = await b.device.sync.select(b.device.sync.integrityAlarms).get();
      expect(alarms.single.kind, 'signature_invalid');
      final peer = await b.device.sync.select(b.device.sync.folderPeers).getSingle();
      expect(peer.cursorOffsetBytes, 0);
      expect(peer.headAuthorSeq, 0);
    });
  });

  group('the folder holds no secrets', () {
    test('no file carries the signing seed', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.pairWith(b);
      await a.attach();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'From A', userId: _userId);
      await a.host.deliverAll();
      final seed = (await a.keyStore.read(a.folderId))!.signSeed;
      final encodedSeed = base64Encode(seed);
      final seedHex = seed.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

      var scanned = 0;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File) continue;
        scanned++;
        final bytes = entity.readAsBytesSync();
        expect(String.fromCharCodes(bytes), isNot(contains(encodedSeed)));
        expect(String.fromCharCodes(bytes), isNot(contains(seedHex)));
        expect(_containsSubsequence(bytes, seed), isFalse, reason: entity.path);
      }
      expect(scanned, greaterThanOrEqualTo(4));
    });
  });

  group('setup', () {
    test('a folder with ops but no folder.json is "still syncing"', () async {
      final directory = _tempFolder();
      Directory('${directory.path}/ops').createSync();
      final device = await FolderDevice.open('a', directory);
      addTearDown(device.close);
      await expectLater(device.bind(), throwsA(isA<FolderSyncRefusal>()));
      expect(File('${directory.path}/$folderFileName').existsSync(), isFalse);
    });

    test('a folder.json that is oversized or has extra fields is refused', () {
      expect(
        () => FolderFile.parse(Uint8List(maxMetadataFileBytes + 1)),
        throwsA(isA<FolderMetadataRefusal>()),
      );
      expect(
        () => FolderFile.parse(Uint8List.fromList(utf8.encode(jsonEncode({
          'format': folderFormatName,
          'version': folderFormatVersion,
          'folder_id': '11111111-2222-3333-4444-555555555555',
          'extra': 1,
        })))),
        throwsA(isA<FolderMetadataRefusal>()),
      );
      expect(
        () => FolderFile.parse(Uint8List.fromList(utf8.encode(jsonEncode({
          'format': folderFormatName,
          'version': 2,
          'folder_id': '11111111-2222-3333-4444-555555555555',
        })))),
        throwsA(isA<FolderMetadataRefusal>()),
      );
    });

    test('turning it off keeps the chain, and turning it on again continues it', () async {
      final directory = _tempFolder();
      final (a, b) = await _unpairedPair(directory);
      await a.pairWith(b);
      await a.attach();
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeA, title: 'First', userId: _userId);
      await a.host.deliverAll();
      await a.host.detach('op-log-folder');
      await a.setup.unbind(a.folderId);
      await expectLater(a.attach(), throwsA(isA<FolderSyncRefusal>()));

      await a.bind();
      await a.attach();
      a.device.wall.advance();
      await a.device.domain.todoDao
          .insertOutcome(id: '4a3e2d5f-6b7c-4d9e-8f01-2b3c4d5e6f70', title: 'Second', userId: _userId);
      await a.host.deliverAll();
      final sequences = [
        for (final envelope in envelopesOf(directory, a.memberId)) headerOf(envelope).authorSeq,
      ];
      expect(sequences, [for (var i = 1; i <= sequences.length; i++) i]);
    });

    test('files this device cannot account for are refused, not continued', () async {
      final directory = _tempFolder();
      final (a, _) = await _unpairedPair(directory);
      // Same folder, same device identity, but a store that has lost its state.
      final fresh = SyncDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      final lostState = FolderSyncSetup(
        database: fresh,
        folder: DartIoSegmentFolder(directory),
        keyStore: a.keyStore,
        isEnrolled: () async => false,
        nowMs: () => 0,
      );
      await expectLater(
        lostState.bind(
          folderLocation: 'x',
          deviceNodeIdHex: a.host.deviceNodeId,
          deviceLabel: 'a',
        ),
        throwsA(isA<FolderSyncRefusal>()),
      );
    });
  });
}

bool _containsSubsequence(Uint8List haystack, Uint8List needle) {
  for (var start = 0; start + needle.length <= haystack.length; start++) {
    var match = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[start + index] != needle[index]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
