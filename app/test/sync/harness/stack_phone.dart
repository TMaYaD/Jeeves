/// One simulated phone, assembled the way production assembles one.
///
/// Where [SimDevice] hand-builds its clients so the convergence suites can reach
/// inside them, this builds a real [SyncStack] over the harness's platform
/// doubles — the store, the key store, the User transport and the clock — and
/// nothing else. Everything between is production code: identity, HLC, the two
/// Workspace clients, the memoising factory *including* its member-transport
/// propagation, the projector attachment, and `EnrolmentService`.
///
/// That matters for #591 specifically. The whole slice is about a device that is
/// **not yet enrolled** and later becomes enrolled, and the propagation of a
/// member credential from the default Workspace's client onto the preferences
/// one is exactly the wiring a `SimDevice` cannot exercise (it hands every client
/// the same omnipresent [DeviceLink] up front).
///
/// Enrolment is deliberately *not* run at construction: [enrolAsFirstDevice] and
/// [enrolWithPassphrase] are separate steps, so a test can write domain rows into
/// a genuinely un-enrolled device first.
library;

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/enrolment.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import 'fake_sync_server.dart';
import 'sim_device.dart';

class StackPhone {
  StackPhone._({
    required this.label,
    required this.stack,
    required this.domain,
    required this.capture,
    required this.link,
    required this.userTransport,
    required this.keyStore,
    required this.syncStore,
    required this.storeDirectory,
    required this.clock,
    required this.lifecycle,
  });

  /// Build the phone. Un-enrolled: no keys, no pinned Root, no member credential.
  ///
  /// [userTransport] lets a test wrap [link] in a decorator so a fault is
  /// injected into the *production* path rather than described in a comment.
  /// [fileBacked] gives the sync store a real file so [relaunch] can prove that
  /// what survives a process death is what the store held.
  static Future<StackPhone> create({
    required String label,
    required String userId,
    required FakeSyncServer server,
    required FakeClock clock,
    UserTransport Function(DeviceLink)? userTransport,
    bool fileBacked = false,
  }) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final storeDirectory =
        fileBacked ? Directory.systemTemp.createTempSync('jeeves-stack-phone-') : null;
    final syncStore = SyncDatabase(
      storeDirectory == null
          ? NativeDatabase.memory()
          : NativeDatabase(File('${storeDirectory.path}/sync.sqlite')),
    );
    final keyStore = InMemoryDeviceKeyStore();
    final link = DeviceLink(server.connectAsUser(userId));
    // The capture seam exists before the store it writes through, and is bound to
    // nothing: this is the pre-enrolment state a real process starts in.
    final capture = WorkspaceRoutingOpCapture();
    final domain = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    // Decorated once and kept: the wrapper is the injected fault, and a relaunch
    // is a process death, not an unwrapping.
    final decorated = userTransport?.call(link) ?? link;
    return StackPhone._(
      label: label,
      stack: await _assemble(
        userId: userId,
        syncStore: syncStore,
        keyStore: keyStore,
        userTransport: decorated,
        domain: domain,
        clock: clock,
      ),
      domain: domain,
      capture: capture,
      link: link,
      userTransport: decorated,
      keyStore: keyStore,
      syncStore: syncStore,
      storeDirectory: storeDirectory,
      clock: clock,
      lifecycle: null,
    );
  }

  static Future<SyncStack> _assemble({
    required String userId,
    required SyncDatabase syncStore,
    required DeviceKeyStore keyStore,
    required UserTransport userTransport,
    required GtdDatabase domain,
    required FakeClock clock,
  }) =>
      // Assembled exactly as `syncStackProvider` assembles it, with the platform
      // parts swapped for the harness's. Both KDF arguments so the floor check
      // still runs on the production path, at a cost a test suite can afford.
      SyncStack.assemble(
        userId: userId,
        database: syncStore,
        keyStore: keyStore,
        userTransport: userTransport,
        domain: domain,
        nowMs: () => clock.nowMs,
        // The platform keychain is unreachable in a unit test; the in-memory store
        // is the same swap `sim_device` makes, so a plaintext_v1 capture's
        // key lookup returns "no key" instead of throwing on the missing channel.
        workspaceKeys: InMemoryWorkspaceKeyStore(),
        kdfParameters: harnessKdfParameters,
        kdfFloor: harnessKdfParameters,
      );

  final String label;
  final GtdDatabase domain;
  final WorkspaceRoutingOpCapture capture;
  final DeviceLink link;

  /// The transport the stack is assembled over: [link] itself, or the decorator a
  /// test wrapped it in. Reused across [relaunch] so an injected fault survives a
  /// process death the way a real server-side fault would.
  final UserTransport userTransport;

  final InMemoryDeviceKeyStore keyStore;
  final Directory? storeDirectory;
  final FakeClock clock;

  SyncStack stack;
  SyncDatabase syncStore;
  SyncLifecycle? lifecycle;

  Future<SyncClient> get preferencesClient =>
      stack.workspaceClientFactory(userPreferencesWorkspaceId(stack.userId));

  Future<EnrolmentOutcome> enrolAsFirstDevice({String? passphrase}) =>
      stack.enrolment.enrolFirstDevice(passphrase: passphrase);

  Future<EnrolmentOutcome> enrolWithPassphrase(String passphrase) =>
      stack.enrolment.enrolWithPassphrase(passphrase);

  /// Build (once) and run the lifecycle — what the app does at launch and after
  /// an enrolment completes.
  ///
  /// The signal listeners run over the harness's timer wheel so no test waits on
  /// a real backoff. [signalTransport] replaces [link] as the socket side only —
  /// what a test wraps to make subscribing itself fail.
  Future<SyncActivation> activate({
    Duration flushDebounce = const Duration(seconds: 3),
    String Function()? mintTagId,
    SyncTransport? signalTransport,
  }) {
    final existing = lifecycle ??= SyncLifecycle(
      stack: stack,
      domain: domain,
      capture: capture,
      signalTransport: signalTransport ?? link,
      timerFactory: link.timers.create,
      listenerDelay: link.timers.delay,
      flushDebounce: flushDebounce,
      mintTagId: mintTagId ?? initialUploadTagIdSequence(label),
    );
    return existing.activate();
  }

  /// Process death: drop the lifecycle, close the sync store and reopen it over
  /// the same file, then assemble a fresh stack from the key store — which is
  /// what a relaunch does. No member credential survives, by design.
  Future<void> relaunch() async {
    final directory = storeDirectory;
    if (directory == null) {
      throw StateError('a memory-backed phone has no file to reopen');
    }
    await lifecycle?.deactivate();
    lifecycle = null;
    await syncStore.close();
    syncStore = SyncDatabase(NativeDatabase(File('${directory.path}/sync.sqlite')));
    stack = await _assemble(
      userId: stack.userId,
      syncStore: syncStore,
      keyStore: keyStore,
      userTransport: userTransport,
      domain: domain,
      clock: clock,
    );
  }

  void goOffline() {
    link.online = false;
    link.dropSignals();
  }

  void goOnline() => link.online = true;

  Future<void> close() async {
    await lifecycle?.deactivate();
    await domain.close();
    await syncStore.close();
    storeDirectory?.deleteSync(recursive: true);
  }
}

/// Deterministic Tag ids for a minted ADR-0025 Label, so a plan built twice on
/// one device mints the same id and two devices cannot collide.
///
/// Production mints a random UUIDv4 (`ids.dart`: only junctions and preferences
/// get deterministic ids); a test needs the id to be predictable to assert on it.
String Function() initialUploadTagIdSequence(String label) {
  var next = 0;
  return () {
    next++;
    // A canonical UUID shape, because `capture()` refuses a non-canonical entity
    // id at the author's own call site (#573).
    final tail = next.toString().padLeft(12, '0');
    final head = label.codeUnits.first.toRadixString(16).padLeft(8, '0');
    return '$head-0000-4000-8000-$tail';
  };
}
