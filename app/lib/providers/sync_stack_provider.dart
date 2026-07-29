/// The op-log stack's production wiring: store, key store, transports, stack.
///
/// **Production sync wiring (#553 Phase 2).** Permanent — the reseed uploader
/// and the PowerSync flip read the same providers. Only the enrolment-ceremony
/// *surface* that currently reaches them is throwaway.
///
/// Nothing here starts syncing. There is no `SignalListener`, no periodic pull
/// and no DAO capture: the running app still writes through PowerSync, and a
/// provider that quietly began pushing ops would be the dual-write branching the
/// proposal's Implementation stance forbids. The stack exists so a ceremony can
/// be run, and so the later slices have one construction site to flip.
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
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
  );
});
