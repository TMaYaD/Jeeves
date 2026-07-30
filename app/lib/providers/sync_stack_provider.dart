/// The op-log stack's production wiring: store, key store, transports, stack.
///
/// **The production sync path.** Assembling the stack does not start syncing —
/// `sync_lifecycle_provider.dart` does that, and only for a device whose own
/// store says it is enrolled. What this provider does is give the device
/// everything it needs: its identity out of the platform key store, its own
/// `jeeves_sync.sqlite`, the User transport on the session Dio, and the domain
/// read model to project into.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../sync/device_key_store.dart';
import '../sync/http_sync_transport.dart';
import '../sync/sync_database.dart';
import '../sync/sync_stack.dart';
import '../sync/sync_store.dart';
import '../sync/sync_transport.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'user_constants.dart';

/// The process-wide op-log store, opened once and closed on disposal.
final FutureProvider<SyncDatabase> syncDatabaseProvider =
    FutureProvider<SyncDatabase>((ref) async {
  ref.keepAlive();
  final database = await SyncStoreImpl().openDatabase();
  ref.onDispose(database.close);
  return database;
});

/// Keychain on iOS/macOS, Keystore-backed on Android.
final Provider<DeviceKeyStore> deviceKeyStoreProvider =
    Provider<DeviceKeyStore>((ref) => const SecureStorageDeviceKeyStore());

/// The User-credential transport, over the session Dio.
///
/// The same Dio the rest of the app talks to the backend with, so the sync
/// routes ride the session bearer token *and* its 401 refresh-and-retry
/// interceptor. The member credential never mixes in: `completeMemberChallenge`
/// builds a separate Dio for it (`http_sync_transport.dart`).
final Provider<UserTransport> userTransportProvider = Provider<UserTransport>(
  (ref) => HttpUserTransport(ref.read(apiServiceProvider).sessionDio),
);

/// The signed-in User's assembled stack.
///
/// Refuses the `'local'` placeholder rather than founding a Workspace for it: a
/// Workspace id is `uuid5` of the user id, so enrolling as `'local'` would mint
/// an escrow and a genesis under an id no account owns, and the real sign-in
/// afterwards could neither reach it nor clean it up.
final FutureProvider<SyncStack> syncStackProvider =
    FutureProvider<SyncStack>((ref) async {
  ref.keepAlive();
  final userId = ref.watch(currentUserIdProvider);
  if (userId == kLocalUserId) {
    throw StateError(
      'sign in before enrolling this device: the Workspace ids, the escrow slot '
      'and the Grants are all derived from the account, not from the local '
      'placeholder user',
    );
  }
  return SyncStack.assemble(
    userId: userId,
    database: await ref.watch(syncDatabaseProvider.future),
    keyStore: ref.watch(deviceKeyStoreProvider),
    userTransport: ref.watch(userTransportProvider),
    // The domain read model, attached at assembly so every client this stack
    // builds projects — including the one the enrolment ceremony pulls through.
    domain: ref.watch(databaseProvider),
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );
});
