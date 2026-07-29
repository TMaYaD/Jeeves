/// Drives the enrolment ceremony from the phone, and says what state it is in.
///
/// **Cutover tooling — removed by #556**, together with the settings entry and
/// the route that reach it. The *ceremony* is permanent product machinery
/// (`sync/enrolment.dart`, `sync/sync_stack.dart`); only this way of starting it
/// by hand is throwaway. When the real onboarding flow lands it calls the same
/// `EnrolmentService` over the same `SyncStack`.
///
/// The screen depends on [EnrolmentCeremonyRunner] and never on the stack, so a
/// widget test scripts states and failures without a store, while the production
/// path is the one `test/sync/enrolment_ceremony_runner_test.dart` drives end to
/// end over the harness's fake server.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/sync_stack_provider.dart';
import '../../sync/control_payload.dart';
import '../../sync/enrolment.dart';
import '../../sync/envelope.dart';
import '../../sync/recovery_escrow.dart';
import '../../sync/sync_stack.dart';
import '../../sync/sync_transport.dart';

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

/// This surface's own refusal, before any network call.
///
/// The no-second-founding rule lives below the UI and not merely in which
/// buttons are drawn: a screen that only hid the button would still found twice
/// on a stale rebuild, and the second attempt would spend a write against an
/// escrow slot that is not this ceremony's to touch.
class EnrolmentCeremonyRefusal implements Exception {
  const EnrolmentCeremonyRefusal(this.message);

  final String message;

  @override
  String toString() => 'EnrolmentCeremonyRefusal: $message';
}

/// Why an attempt failed, in the only categories the screen acts on.
enum EnrolmentCeremonyFailure {
  /// No response at all. Nothing was founded, and nothing was written.
  serverUnreachable,

  /// The slot already holds an escrow for this account.
  escrowAlreadyExists,

  /// The blob did not authenticate — the one failure that is a prompt.
  wrongPassphrase,

  /// There is no escrow to enrol against.
  missingEscrow,

  /// A server-integrity event: a substituted or rolled-back blob, a below-floor
  /// one, or a KDF this platform refuses. Never shown as "wrong passphrase".
  integrityAlarm,

  /// This surface refused before touching the network.
  refused,

  /// Anything else, shown raw.
  unknown,
}

EnrolmentCeremonyFailure classifyEnrolmentCeremonyFailure(Object error) {
  if (error is EnrolmentCeremonyRefusal) return EnrolmentCeremonyFailure.refused;
  if (error is SyncTransportException) {
    if (error.isUnreachable) return EnrolmentCeremonyFailure.serverUnreachable;
    // Two codes, one meaning. A fresh device founding an account somebody
    // already founded signs with its own Root, so the server refuses the
    // signature (403) before it ever compares versions; the version conflict
    // (409) is the same Root re-writing its own slot.
    return error.code == badEscrowSignatureCode ||
            error.code == escrowVersionRegressionCode
        ? EnrolmentCeremonyFailure.escrowAlreadyExists
        : EnrolmentCeremonyFailure.unknown;
  }
  if (error is RecoveryEscrowException) {
    return switch (error.failure) {
      RecoveryEscrowFailure.wrongPassphrase =>
        EnrolmentCeremonyFailure.wrongPassphrase,
      RecoveryEscrowFailure.noEscrowStored =>
        EnrolmentCeremonyFailure.missingEscrow,
      _ => EnrolmentCeremonyFailure.integrityAlarm,
    };
  }
  return EnrolmentCeremonyFailure.unknown;
}

/// What the screen says about [failure], with [error] appended where the raw
/// text is the only honest thing to show.
String enrolmentCeremonyFailureMessage(
  EnrolmentCeremonyFailure failure,
  Object error,
) =>
    switch (failure) {
      EnrolmentCeremonyFailure.serverUnreachable =>
        'Server unreachable — nothing was founded. Run it again; the '
            'passphrase above protected nothing and a fresh one will be '
            'generated.',
      EnrolmentCeremonyFailure.escrowAlreadyExists =>
        'An escrow already exists for this account, so this device cannot found '
            'it. If you hold the passphrase, enrol against the existing escrow '
            'below.',
      EnrolmentCeremonyFailure.wrongPassphrase =>
        'That passphrase did not open the escrow. Nothing was changed — check '
            'it and try again.',
      EnrolmentCeremonyFailure.missingEscrow =>
        'This account has no recovery escrow to enrol against.',
      EnrolmentCeremonyFailure.integrityAlarm =>
        'The escrow the server served is not the one this device trusts. '
            'Refusing rather than guessing: $error',
      EnrolmentCeremonyFailure.refused => '$error',
      EnrolmentCeremonyFailure.unknown => 'The ceremony failed: $error',
    };

abstract class EnrolmentCeremonyRunner {
  /// Read the store. **No network**: the answer must be the same offline, and a
  /// relaunched device holds no member credential to ask with anyway.
  Future<EnrolmentCeremonyStatus> status();

  /// A fresh diceware passphrase, drawn under the *service's* own policy so the
  /// phrase offered and the phrase accepted cannot drift apart. Async for that
  /// reason only.
  Future<String> generatePassphrase();

  /// Found the account: mint Root, escrow it, register, genesis, owner Grant.
  Future<EnrolmentOutcome> found(String passphrase);

  /// Re-enter an unfinished (or another device's) ceremony with the passphrase.
  ///
  /// In scope because it is what makes "never half-founded" true rather than
  /// asserted: after the escrow PUT lands, founding again can only ever return
  /// `escrow_version_regression`, so without this the one production phone would
  /// be permanently stuck in [EnrolmentState.foundingIncomplete]. It is zero new
  /// ceremony logic — `enrolWithPassphrase` verbatim.
  Future<EnrolmentOutcome> resume(String passphrase);
}

/// The real runner, over an assembled [SyncStack].
///
/// Takes the stack as a closure so production reads it off a provider and the
/// integration test hands over a harness-built one — the *same* code path,
/// including `SyncStack`'s member-transport propagation, which is the one part of
/// the wiring the harness's own fakes cannot stand in for.
class StackEnrolmentCeremonyRunner implements EnrolmentCeremonyRunner {
  StackEnrolmentCeremonyRunner(this._stack);

  final Future<SyncStack> Function() _stack;

  @override
  Future<EnrolmentCeremonyStatus> status() async {
    final stack = await _stack();
    final workspaceIds = stack.workspaceIds;
    final founded = <String>[];
    for (final workspaceId in workspaceIds) {
      final client = await stack.workspaceClientFactory(workspaceId);
      final head = await client.appliedControlHead();
      if (!sameBytes(head, zeroPrevControlHash)) founded.add(workspaceId);
    }
    return deriveEnrolmentCeremonyStatus(
      workspaceIds: workspaceIds,
      foundedWorkspaceIds: founded,
      storedMemberId: (await stack.keyStore.read(stack.defaultClient.workspaceId))
          ?.memberId,
      pinnedRootPk: await stack.defaultClient.pinnedRootPk(),
      highestEscrowVersionSeen:
          await stack.defaultClient.highestEscrowVersionSeen(),
    );
  }

  @override
  Future<String> generatePassphrase() async =>
      (await _stack()).passphrasePolicy.generate();

  @override
  Future<EnrolmentOutcome> found(String passphrase) async {
    final current = await status();
    if (current.state != EnrolmentState.notEnrolled) {
      throw EnrolmentCeremonyRefusal(
        current.state == EnrolmentState.enrolled
            ? 'this device is already enrolled — founding again would try to '
                'replace an escrow it does not own'
            : 'a ceremony on this device already claimed the escrow — enrol '
                'against it with the passphrase instead of founding again',
      );
    }
    return (await _stack()).enrolment.enrolFirstDevice(passphrase: passphrase);
  }

  @override
  Future<EnrolmentOutcome> resume(String passphrase) async {
    if ((await status()).state == EnrolmentState.enrolled) {
      throw const EnrolmentCeremonyRefusal(
        'this device is already enrolled — there is nothing to resume',
      );
    }
    return (await _stack()).enrolment.enrolWithPassphrase(passphrase);
  }
}

final enrolmentCeremonyRunnerProvider = Provider<EnrolmentCeremonyRunner>(
  (ref) => StackEnrolmentCeremonyRunner(
    () => ref.read(syncStackProvider.future),
  ),
);
