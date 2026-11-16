/// Production wiring for the op-log folder plugin: the platform's folder access,
/// the controller the settings screen drives, and the health the indicator reads.
///
/// Folder sync is for a device that is not signed in and not enrolled; the
/// controller's [EnrolmentCheck] says so from both sources, and the plugin and the
/// setup refuse on it independently of what any screen shows.
library;

import 'dart:async';

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sync/folder/android_segment_folder.dart';
import '../sync/folder/folder_health.dart';
import '../sync/folder_sync_controller.dart';
import '../sync/folder/segment_folder.dart';
import '../sync/host/hosted_capture.dart';
import '../sync/sync_health.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

/// What a platform gives the folder plugin: a way to choose a folder, and to open
/// the one that was chosen.
abstract class FolderPlatform {
  bool get isAvailable;

  /// Show the folder picker; the stored location, or null if cancelled.
  Future<String?> pickFolder();

  SegmentFolder open(String location);
}

class AndroidFolderPlatform implements FolderPlatform {
  const AndroidFolderPlatform();

  @override
  bool get isAvailable => true;

  @override
  Future<String?> pickFolder() => pickAndroidFolder();

  @override
  SegmentFolder open(String location) => AndroidSegmentFolder(location);
}

/// Web and any other platform: the entry is not shown.
class UnavailableFolderPlatform implements FolderPlatform {
  const UnavailableFolderPlatform();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> pickFolder() async => null;

  @override
  SegmentFolder open(String location) =>
      throw UnsupportedError('Folder sync is not available on this platform');
}

final Provider<FolderPlatform> folderPlatformProvider = Provider<FolderPlatform>(
  // `Platform`, not `defaultTargetPlatform`: a widget test reports Android there.
  (ref) => !kIsWeb && Platform.isAndroid
      ? const AndroidFolderPlatform()
      : const UnavailableFolderPlatform(),
);

final FutureProvider<FolderSyncController> folderSyncControllerProvider =
    FutureProvider<FolderSyncController>((ref) async {
  ref.keepAlive();
  final platform = ref.watch(folderPlatformProvider);
  final domain = ref.read(databaseProvider);
  return FolderSyncController(
    host: await ref.watch(syncHostProvider.future),
    database: await ref.watch(syncDatabaseProvider.future),
    keyStore: ref.watch(deviceKeyStoreProvider),
    openFolder: platform.open,
    isEnrolled: () async {
      if (ref.read(currentUserIdProvider) != kLocalUserId) return true;
      return (await readClockIdentity(domain)).enrolledMemberIdHex != null;
    },
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );
});

/// Brings an active folder binding back at launch. Eagerly watched from `main.dart`.
final FutureProvider<void> folderSyncResumeProvider = FutureProvider<void>((ref) async {
  ref.keepAlive();
  if (!ref.watch(folderPlatformProvider).isAvailable) return;
  try {
    await (await ref.watch(folderSyncControllerProvider.future)).resume();
  } on Object catch (error) {
    debugPrint('folder sync: resume failed — $error');
  }
});

/// The settings screen's view; invalidate it after any change.
final folderSyncSummaryProvider =
    FutureProvider.autoDispose<FolderSyncSummary?>((ref) async {
  final controller = await ref.watch(folderSyncControllerProvider.future);
  return controller.summary();
});

/// The active folder's rows, live, or null while folder sync is off.
final StreamProvider<FolderSyncRows?> folderSyncRowsProvider =
    StreamProvider<FolderSyncRows?>((ref) async* {
  final controller = await ref.watch(folderSyncControllerProvider.future);
  final binding = await controller.activeBinding();
  if (binding == null) {
    yield null;
    return;
  }
  yield* watchFolderSyncRows(controller.database, binding.folderId);
});

/// The active folder's health, for the indicator. Null while folder sync is off.
final Provider<AsyncValue<SyncHealth?>> folderSyncHealthProvider =
    Provider<AsyncValue<SyncHealth?>>((ref) =>
        ref.watch(folderSyncRowsProvider).whenData((rows) => rows == null ? null : folderHealthOf(rows)));
