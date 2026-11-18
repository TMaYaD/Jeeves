/// The device's names: the name this device gives itself, and the names of the
/// peers it has been shown.
///
/// One [DeviceNames] over the domain store, so the write path and the read path
/// are the same object: a name this device writes is the name it can read back,
/// and there is no second place where a name could be kept.
///
/// **The peer check needs an account, and a signed-out device has none.** A
/// device that is not signed in has no preferences Workspace and no Grants, so
/// no peer could be verified; the predicate says so rather than reaching for a
/// stack that would refuse to assemble.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/platform_device_name.dart';
import '../sync/device_names.dart';
import '../sync/ids.dart' show userPreferencesWorkspaceId;
import 'auth_provider.dart';
import 'database_provider.dart';
import 'sync_stack_provider.dart';
import 'user_constants.dart';

/// This device's names, and the resolver for the peers'.
///
/// The verification predicate is read lazily, at the moment a peer's name is
/// asked for: the signed-in user can change between two reads, and a predicate
/// that captured the account at build time would keep answering for an account
/// nobody is signed into any more.
final deviceNamesProvider = Provider<DeviceNames>((ref) {
  return DeviceNames(
    db: ref.watch(databaseProvider),
    readPlatformName: readPlatformDeviceName,
    isVerifiedDevice: (nodeIdHex) async {
      final userId = ref.read(currentUserIdProvider);
      if (userId == kLocalUserId) {
        // Signed out: there is no preferences Workspace to hold a Grant, so no
        // peer is verified. The local profile's own name is still readable —
        // that is this device's, not a peer's.
        return false;
      }
      final stack = await ref.read(syncStackProvider.future);
      final preferencesClient = await stack.workspaceClientFactory(
        userPreferencesWorkspaceId(stack.userId),
      );
      return deviceHasAppliedGrant(preferencesClient, nodeIdHex);
    },
  );
});

/// This device's own name, as it changes.
///
/// `null` until the device has a name — and `null` again for a signed-out
/// device whose name has not been written yet. The caller phrases the missing
/// name itself.
final thisDeviceNameProvider = StreamProvider<String?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  return ref.watch(deviceNamesProvider).watchThisDeviceName(userId);
});
