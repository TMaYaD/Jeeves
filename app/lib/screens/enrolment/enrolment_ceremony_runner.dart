/// Drives the enrolment ceremony from the phone, and says what state it is in.
///
/// The ceremony is the app's onboarding step: signing in or up leads here, and a
/// device leaves it enrolled and syncing. The machinery it drives lives in
/// `sync/enrolment.dart` and `sync/sync_stack.dart`; this is the surface's own
/// seam onto it.
///
/// The screen depends on [EnrolmentCeremonyRunner] and never on the stack, so a
/// widget test scripts states and failures without a store, while the production
/// path is the one `test/sync/enrolment_ceremony_runner_test.dart` drives end to
/// end over the harness's fake server.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/session_gate.dart';
import '../../providers/sync_lifecycle_provider.dart';
import '../../providers/sync_stack_provider.dart';
import '../../sync/enrolment.dart';
import '../../sync/enrolment_state.dart';
import '../../sync/recovery_escrow.dart';
import '../../sync/sync_stack.dart';
import '../../sync/sync_transport.dart';

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
  /// No response to *this* request. Says nothing about what already committed:
  /// the escrow PUT is one of seven steps, and a lost response to it is
  /// indistinguishable from one that never arrived. The passphrase is kept.
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
        'Server unreachable — this attempt did not finish, and whether the '
            'escrow write reached the server is not knowable from here. Keep '
            'this passphrase: it is the only thing that can finish a ceremony '
            'that got that far. The state shown was re-read from this device — '
            'run it again, and enrol with the passphrase if it turns out the '
            'escrow already exists.',
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

  /// Whether this account's recovery-escrow slot is already occupied.
  ///
  /// The one question [status] cannot answer, and the one the screen needs to
  /// decide which door to open: a store that says `notEnrolled` looks identical
  /// on the first device of a new account and on the second device of an
  /// existing one. Founding is only possible in the first case — in the second
  /// the escrow PUT could only ever be refused — so the presentation is chosen
  /// from this, not guessed from the store.
  ///
  /// Over the *User* credential, so a device with no member credential can ask.
  Future<bool> escrowExists();

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
  StackEnrolmentCeremonyRunner(this._stack, {Future<void> Function()? onEnrolled})
      : _onEnrolled = onEnrolled;

  final Future<SyncStack> Function() _stack;

  /// Start syncing, once a ceremony has produced an enrolled device.
  ///
  /// It drives the same `SyncLifecycle.activate` over the same `SyncStack` that
  /// the app calls at every launch, so a missed call here costs one relaunch
  /// rather than a device that never syncs.
  final Future<void> Function()? _onEnrolled;

  @override
  Future<EnrolmentCeremonyStatus> status() async =>
      (await _stack()).readEnrolmentStatus();

  @override
  Future<bool> escrowExists() async {
    final stack = await _stack();
    return await stack.userTransport
            .fetchRecoveryEscrow(stack.defaultClient.workspaceId) !=
        null;
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
    final outcome =
        await (await _stack()).enrolment.enrolFirstDevice(passphrase: passphrase);
    await _onEnrolled?.call();
    return outcome;
  }

  @override
  Future<EnrolmentOutcome> resume(String passphrase) async {
    if ((await status()).state == EnrolmentState.enrolled) {
      throw const EnrolmentCeremonyRefusal(
        'this device is already enrolled — there is nothing to resume',
      );
    }
    final outcome =
        await (await _stack()).enrolment.enrolWithPassphrase(passphrase);
    await _onEnrolled?.call();
    return outcome;
  }
}

final enrolmentCeremonyRunnerProvider = Provider<EnrolmentCeremonyRunner>(
  (ref) => StackEnrolmentCeremonyRunner(
    () => ref.read(syncStackProvider.future),
    onEnrolled: () async {
      // Onboarding is finished, so the router stops pinning the device here.
      // Flipped before the activation because activation is a network round trip
      // and possibly a walk of the whole store: the user should not be held on
      // the ceremony screen waiting for their first upload.
      sessionGateNotifier.value = SessionGate.ready;
      final lifecycle = await ref.read(syncLifecycleProvider.future);
      if (lifecycle == null) return;
      await activateAndLog(lifecycle);
    },
  ),
);
