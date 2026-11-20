/// Turning folder sync on from the screen, pairing, and turning it off — through
/// the real controller, plugin, stores and a real temporary folder.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/folder_sync_provider.dart';
import 'package:jeeves/screens/folder_sync/folder_sync_screen.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/folder_sync_controller.dart';
import 'package:jeeves/sync/folder/segment_folder.dart';
import 'package:jeeves/sync/host/sync_host_service.dart';

import '../sync/folder/folder_harness.dart';
import '../sync/host/host_harness.dart';

class _TestPlatform implements FolderPlatform {
  _TestPlatform(this.directory);

  final Directory directory;

  @override
  bool get isAvailable => true;

  @override
  Future<String?> pickFolder() async => directory.path;

  @override
  SegmentFolder open(String location) => DartIoSegmentFolder(Directory(location));
}

Future<void> _eventually(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('never found $finder');
}

void main() {
  late Directory directory;
  late HostDevice deviceA;
  late SyncHostService hostA;
  late FolderDevice deviceB;
  late FolderSyncController controller;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('folder-screen-');
    addTearDown(() => directory.deleteSync(recursive: true));
    deviceB = await FolderDevice.open('b-phone', directory);
    addTearDown(() => deviceB.close());
    await deviceB.bind();
    deviceA = HostDevice.open('a');
    addTearDown(() => deviceA.close());
    hostA = await deviceA.startHost();
    addTearDown(() => hostA.stopPlugins());
    controller = FolderSyncController(
      host: hostA,
      database: deviceA.sync,
      keyStore: InMemoryDeviceKeyStore(),
      openFolder: (location) => DartIoSegmentFolder(Directory(location)),
      isEnrolled: () async => false,
      nowMs: () => deviceA.wall.nowMs,
    );
  });

  testWidgets('choose a folder, pair the other device, turn it off', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        folderPlatformProvider.overrideWithValue(_TestPlatform(directory)),
        folderSyncControllerProvider.overrideWith((ref) async => controller),
      ],
      child: const MaterialApp(home: FolderSyncScreen()),
    ));
    await _eventually(tester, find.byKey(const Key('folder_sync_choose')));
    expect(find.byKey(const Key('folder_sync_permanent_warning')), findsOneWidget);

    // Declining the confirmation writes nothing.
    await tester.tap(find.byKey(const Key('folder_sync_choose')));
    await tester.pumpAndSettle();
    expect(find.textContaining('does not encrypt this folder'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    final ownDirectories = await tester.runAsync(() => DartIoSegmentFolder(directory)
        .listDirectories('ops')
        .then((names) => names.where((name) => name != deviceB.memberId).toList()));
    expect(ownDirectories, isEmpty);

    await tester.tap(find.byKey(const Key('folder_sync_choose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('folder_sync_accept_unencrypted')));
    await _eventually(tester, find.byKey(const Key('folder_sync_fingerprint')));
    expect(find.byKey(Key('folder_sync_member_${deviceB.memberId}')), findsOneWidget);
    expect(find.textContaining('Not paired'), findsOneWidget);

    await tester.tap(find.byKey(Key('folder_sync_pair_${deviceB.memberId}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('check that its key fingerprint reads'), findsOneWidget);
    await tester.tap(find.byKey(const Key('folder_sync_confirm_pair')));
    await _eventually(tester, find.text('Paired'));

    await tester.tap(find.byKey(const Key('folder_sync_turn_off')));
    await tester.pumpAndSettle();
    expect(find.textContaining('stay there'), findsOneWidget);
    await tester.tap(find.byKey(const Key('folder_sync_confirm_turn_off')));
    await _eventually(tester, find.byKey(const Key('folder_sync_choose')));
  });
}
