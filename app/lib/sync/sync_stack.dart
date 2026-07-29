/// One device's op-log stack, assembled: identity, clock, clients, ceremony.
///
/// **Production sync wiring (#553 Phase 2).** Permanent product machinery — the
/// reseed uploader and the PowerSync flip build on this same assembly, so it is
/// deliberately *not* marked as cutover tooling even though the first thing to
/// reach it is the throwaway enrolment-ceremony surface.
///
/// Everything a real device needs to run the enrolment ceremony and to sync,
/// with every platform part injected: the store, the key store, the User
/// transport and the clock. That is what lets the multi-device harness assemble
/// the *same* closure production runs — including the member-transport
/// propagation below, which no harness fake can stand in for.
///
/// Not here, on purpose: the domain projector and the DAO capture seam. The
/// running app still writes through PowerSync (`NoopDomainOpCapture`), so a
/// stack that attached a projector would be claiming a flip that has not
/// happened. #553's later slices add it at this one site.
library;

import 'dart:math';

import 'device_key_store.dart';
import 'enrolment.dart';
import 'hlc.dart';
import 'ids.dart';
import 'member_identity.dart';
import 'merge_strategy.dart';
import 'passphrase_policy.dart';
import 'recovery_escrow.dart';
import 'reducer.dart';
import 'sync_client.dart';
import 'sync_database.dart';
import 'sync_transport.dart';

class SyncStack {
  SyncStack._({
    required this.userId,
    required this.database,
    required this.keyStore,
    required this.identity,
    required this.clock,
    required this.nowMs,
    required this.strategies,
    required this.defaultClient,
    required this.workspaceClientFactory,
    required this.enrolment,
    required this.passphrasePolicy,
  });

  /// Build the whole stack for [userId].
  ///
  /// The identity comes out of [keyStore] when this device has enrolled before,
  /// so a relaunch is the *same* Member rather than a stranger registering
  /// itself twice — that is what the store holds seeds for.
  ///
  /// **The member credential is not restored here, and cannot be.** It is
  /// minted by the proof-of-possession exchange and held in memory only, so a
  /// relaunched enrolled device has its keys, its pin and its whole log, and no
  /// transport until a ceremony (or a later #553 slice that persists the token)
  /// gives it one. Every read the ceremony surface makes is therefore a local
  /// read.
  static Future<SyncStack> assemble({
    required String userId,
    required SyncDatabase database,
    required DeviceKeyStore keyStore,
    required UserTransport userTransport,
    required int Function() nowMs,
    MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
    PassphrasePolicy passphrasePolicy = const PassphrasePolicy(),
    Argon2idParameters kdfParameters = Argon2idParameters.floor,
    Argon2idParameters kdfFloor = Argon2idParameters.floor,
    Random? random,
  }) async {
    final stored = await keyStore.read(defaultWorkspaceId(userId));
    final identity = stored == null
        ? await MemberIdentity.generate()
        : await MemberIdentity.generate(
            memberId: stored.memberId,
            signSeed: stored.signSeed,
            kexSeed: stored.kexSeed,
          );
    final clock = HlcClock(memberIdHex: identity.memberIdHex, nowMs: nowMs);
    DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true);

    final defaultClient = SyncClient(
      workspaceId: defaultWorkspaceId(userId),
      userId: userId,
      identity: identity,
      database: database,
      clock: clock,
      reducer: Reducer(database, nowMs: nowMs, strategies: strategies),
      now: now,
    );

    // One client per Workspace over the *same* store, identity, clock and
    // member directory: a device is two Workspaces of one User, not two devices.
    final clientsByWorkspaceId = <String, SyncClient>{
      defaultClient.workspaceId: defaultClient,
    };
    Future<SyncClient> workspaceClientFactory(String scopedWorkspaceId) async {
      final scoped = clientsByWorkspaceId.putIfAbsent(
        scopedWorkspaceId,
        () => SyncClient(
          workspaceId: scopedWorkspaceId,
          userId: userId,
          identity: identity,
          database: database,
          clock: clock,
          reducer: Reducer(database, nowMs: nowMs, strategies: strategies),
          // The one directory, so a Member chained in one Workspace is not a
          // stranger in the other.
          directory: defaultClient.directory,
          now: now,
        ),
      );
      // **Lazily, on every call, and never at construction.** The ceremony
      // reaches this factory twice at different points of its own progress:
      // once at step 2 (`_writeEscrowSlot`) while no member credential exists
      // yet, and again at step 6 (`_claimPlaceIn`) to pull and claim. Attaching
      // only in the `putIfAbsent` body would build the preferences client
      // un-enrolled and leave it that way, and step 6's pull would throw
      // `StateError` — the ceremony would die on the preferences Workspace every
      // single time. The harness cannot catch that, because a `SimDevice` hands
      // every client the same omnipresent `DeviceLink` up front.
      if (defaultClient.isEnrolled && !scoped.isEnrolled) {
        scoped.useMemberTransport(defaultClient.transport);
      }
      return scoped;
    }

    return SyncStack._(
      userId: userId,
      database: database,
      keyStore: keyStore,
      identity: identity,
      clock: clock,
      nowMs: nowMs,
      strategies: strategies,
      defaultClient: defaultClient,
      workspaceClientFactory: workspaceClientFactory,
      enrolment: EnrolmentService(
        client: defaultClient,
        userTransport: userTransport,
        keyStore: keyStore,
        workspaceClientFactory: workspaceClientFactory,
        nowMs: nowMs,
        passphrasePolicy: passphrasePolicy,
        kdfParameters: kdfParameters,
        kdfFloor: kdfFloor,
        random: random,
      ),
      passphrasePolicy: passphrasePolicy,
    );
  }

  final String userId;

  /// The convergence substrate. Owned by whoever built the stack — the provider
  /// closes it, so nothing here does.
  final SyncDatabase database;

  final DeviceKeyStore keyStore;
  final MemberIdentity identity;
  final HlcClock clock;

  /// The wall clock every [Reducer] on this device reads, and the strategy
  /// registry every one of them arbitrates under.
  ///
  /// Both are held rather than merely used at assembly because a later slice may
  /// have to build a *second* reducer over the same device — #553's reseed
  /// verification builds a throwaway one to reduce the server log from zero — and
  /// a second reducer reading a different clock or a different registry would
  /// measure the tooling instead of the data: the skew guard's verdict and which
  /// lattice arbitrates a preference are both inputs to what reduction produces.
  final int Function() nowMs;
  final MergeStrategyRegistry strategies;

  /// The client for the default (GTD) Workspace.
  final SyncClient defaultClient;

  /// Memoising, and the one place the member transport propagates. See the
  /// closure's own comment for why the attach cannot move into construction.
  final Future<SyncClient> Function(String workspaceId) workspaceClientFactory;

  final EnrolmentService enrolment;

  /// The policy the ceremony generates and rates passphrases under, so a screen
  /// offering "generate one for me" cannot drift from what the service accepts.
  final PassphrasePolicy passphrasePolicy;

  /// Every Workspace this User's devices reach without a Grant round-trip.
  List<String> get workspaceIds => derivableWorkspaceIds(userId);
}
