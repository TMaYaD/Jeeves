/// What this device's own store says about its enrolment, and how to read it.
///
/// **Permanent sync-layer machinery.** Three callers derive the same three states
/// from the same evidence: `sync_lifecycle.dart` decides whether to attach a
/// transport and author anything, the session gate decides what Settings offers
/// (never where the user is — #673), and the enrolment surface decides which
/// controls to show. Deriving it more than once is how they would drift.
///
/// Read from the store alone — **no network**. The answer must be the same
/// offline, and a relaunched enrolled device holds no member credential to ask
/// with anyway (the credential is minted by a proof-of-possession exchange and
/// held in memory only).
library;

import 'dart:typed_data';

/// Where this device is in the ceremony, read from the store alone.
///
/// Three states rather than a boolean, because the ceremony has crash windows
/// and a device sitting in one is neither enrolled nor free to start over.
enum EnrolmentState {
  /// Nothing has happened: no keys, and no pinned Root. The only state from
  /// which founding is allowed.
  notEnrolled,

  /// The ceremony started and did not finish. Two shapes reach here, and both
  /// are recovered the same way — re-enter with the passphrase:
  ///
  /// - **Keys present, a Workspace still un-founded.** The escrow and the pin
  ///   landed, the log did not.
  /// - **A pinned Root with no keys.** `enrolFirstDevice` writes the escrow and
  ///   pins Root *before* it stores the keypairs, so dying in that window leaves
  ///   the account's escrow claimed by a device that cannot prove it. Founding
  ///   again could only ever return `escrow_version_regression`, which is why
  ///   this is not [notEnrolled].
  foundingIncomplete,

  /// Keys stored and every derivable Workspace's control log non-empty.
  enrolled,
}

/// What the store says, and the evidence a screen shows for it.
class EnrolmentCeremonyStatus {
  const EnrolmentCeremonyStatus({
    required this.state,
    required this.workspaceIds,
    required this.foundedWorkspaceIds,
    this.memberId,
    this.rootPkFingerprint,
    this.escrowVersion,
  });

  final EnrolmentState state;

  /// Every Workspace this User's devices are enrolled into, in ceremony order.
  final List<String> workspaceIds;

  /// Those whose control log this device has applied something into.
  final List<String> foundedWorkspaceIds;

  /// This device's Member id, once its keys are stored. Null in the pre-keys
  /// crash window — the ceremony minted an identity that nothing recorded.
  final String? memberId;

  /// The first eight bytes of the pinned Root, hex — enough to read off the
  /// screen and compare with another device, and not the key itself.
  final String? rootPkFingerprint;

  /// The highest escrow version this device has accepted, or null before it has
  /// accepted one.
  final int? escrowVersion;
}

/// Derive the state from what the store holds. Pure, so the branch table is
/// asserted directly rather than through four staged ceremony failures.
EnrolmentCeremonyStatus deriveEnrolmentCeremonyStatus({
  required List<String> workspaceIds,
  required List<String> foundedWorkspaceIds,
  required String? storedMemberId,
  required Uint8List? pinnedRootPk,
  required int highestEscrowVersionSeen,
}) {
  final founded = foundedWorkspaceIds.toSet();
  final EnrolmentState state;
  if (storedMemberId == null) {
    // Keys are ceremony step 3 of 7, so their absence alone says nothing about
    // whether the escrow was claimed. The pin does: it is written immediately
    // after the escrow PUT the account can never take back.
    state = pinnedRootPk == null
        ? EnrolmentState.notEnrolled
        : EnrolmentState.foundingIncomplete;
  } else {
    state = workspaceIds.every(founded.contains)
        ? EnrolmentState.enrolled
        : EnrolmentState.foundingIncomplete;
  }
  return EnrolmentCeremonyStatus(
    state: state,
    workspaceIds: workspaceIds,
    foundedWorkspaceIds: [
      for (final workspaceId in workspaceIds)
        if (founded.contains(workspaceId)) workspaceId,
    ],
    memberId: storedMemberId,
    rootPkFingerprint: pinnedRootPk == null ? null : _fingerprint(pinnedRootPk),
    escrowVersion: highestEscrowVersionSeen == 0 ? null : highestEscrowVersionSeen,
  );
}

String _fingerprint(Uint8List rootPk) => rootPk
    .take(8)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
