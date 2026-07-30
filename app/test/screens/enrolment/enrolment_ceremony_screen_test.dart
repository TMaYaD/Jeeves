/// The enrolment ceremony surface over a scripted runner.
///
/// What is asserted here is what the screen is *for*: the account's escrow slot
/// decides whether this device founds or joins, the passphrase is shown once and
/// confirmed before anything runs, an enrolled device is offered no second
/// founding, a half-founded one is offered the passphrase, every failure says
/// what it left behind — and the window carries `FLAG_SECURE` while the secret is
/// on it. The ceremony itself is
/// `test/sync/enrolment_ceremony_runner_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/screens/enrolment/enrolment_ceremony_runner.dart';
import 'package:jeeves/screens/enrolment/enrolment_ceremony_screen.dart';
import 'package:jeeves/services/secure_screen.dart';
import 'package:jeeves/sync/enrolment.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/passphrase_policy.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/sync_transport.dart';

const String _generated = 'correct horse battery staple ribbon anvil';

EnrolmentCeremonyStatus _status(
  EnrolmentState state, {
  String? memberId,
  List<String> founded = const [],
}) =>
    EnrolmentCeremonyStatus(
      state: state,
      workspaceIds: const ['workspace-default', 'workspace-preferences'],
      foundedWorkspaceIds: founded,
      memberId: memberId,
      rootPkFingerprint: state == EnrolmentState.notEnrolled ? null : 'a1b2c3d4',
      escrowVersion: state == EnrolmentState.notEnrolled ? null : 1,
    );

/// Scripted states and outcomes. Every state transition a real run produces —
/// found, then re-read — is expressed as a queue of statuses, because "the screen
/// shows the store's truth after an attempt, not the attempt's hope" is exactly
/// the behaviour under test.
class _StubRunner implements EnrolmentCeremonyRunner {
  _StubRunner(
    this._statuses, {
    this.foundFailure,
    this.resumeFailure,
    this.escrow = false,
    this.escrowProbeFailure,
  });

  final List<EnrolmentCeremonyStatus> _statuses;
  final Object? foundFailure;
  final Object? resumeFailure;

  /// What the account's escrow slot holds. `false` — an empty slot, i.e. a fresh
  /// account this device founds — is the default because it is the case most of
  /// the older cases here were written against.
  final bool escrow;
  final Object? escrowProbeFailure;

  int statusReads = 0;
  int escrowProbes = 0;
  int generated = 0;
  final List<String> foundedWith = [];
  final List<String> resumedWith = [];

  @override
  Future<EnrolmentCeremonyStatus> status() async {
    final index = statusReads < _statuses.length ? statusReads : _statuses.length - 1;
    statusReads++;
    return _statuses[index];
  }

  @override
  Future<bool> escrowExists() async {
    escrowProbes++;
    if (escrowProbeFailure case final failure?) throw failure;
    return escrow;
  }

  @override
  Future<String> generatePassphrase() async {
    generated++;
    return _generated;
  }

  @override
  Future<EnrolmentOutcome> found(String passphrase) async {
    foundedWith.add(passphrase);
    if (foundFailure case final failure?) throw failure;
    return _outcome(passphrase);
  }

  @override
  Future<EnrolmentOutcome> resume(String passphrase) async {
    resumedWith.add(passphrase);
    if (resumeFailure case final failure?) throw failure;
    return _outcome(passphrase);
  }

  static EnrolmentOutcome _outcome(String passphrase) => EnrolmentOutcome(
        passphrase: passphrase,
        strength: const PassphrasePolicy().strengthOfGenerated(),
        isFirstDevice: true,
        escrowVersion: firstEscrowVersion,
        rootPk: Uint8List(32),
      );
}

/// Every `FLAG_SECURE` request the screen made, in order.
List<bool> _recordSecureScreenCalls(WidgetTester tester) {
  final calls = <bool>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    secureScreenChannel,
    (call) async {
      if (call.method == 'setSecure') {
        calls.add((call.arguments as Map)['secure'] as bool);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(secureScreenChannel, null),
  );
  return calls;
}

Future<R> _pump<R extends EnrolmentCeremonyRunner>(
  WidgetTester tester,
  R runner,
) async {
  // A viewport tall enough for the whole page. A `ListView` only inflates the
  // children near the visible window, so on the default 800px-high test surface
  // the confirmation checkbox and the founding button are *absent* from the tree
  // rather than merely off screen — and a finder that misses them would read as
  // "the screen does not offer founding", which is the exact claim other cases
  // here make on purpose.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        enrolmentCeremonyRunnerProvider.overrideWithValue(runner),
      ],
      child: const MaterialApp(home: EnrolmentCeremonyScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return runner;
}

Future<void> _tapScrolled(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the window is secured on open and released on close',
      (tester) async {
    final calls = _recordSecureScreenCalls(tester);
    await _pump(tester, _StubRunner([_status(EnrolmentState.notEnrolled)]));

    expect(calls, [true], reason: 'the recents thumbnail is taken unprompted');

    // Replacing the whole tree disposes the screen, which is the only place the
    // flag can be cleared: it is window-scoped, so leaving it set would silently
    // make every later screen unscreenshottable.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
  });

  testWidgets('nothing is generated or founded until the user asks',
      (tester) async {
    final runner =
        await _pump(tester, _StubRunner([_status(EnrolmentState.notEnrolled)]));

    expect(find.byKey(const Key('enrolment_state_not_enrolled')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_generate_button')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_passphrase')), findsNothing);
    expect(find.byKey(const Key('enrolment_found_button')), findsNothing);
    expect(runner.generated, 0);
    expect(runner.foundedWith, isEmpty);
    // The blurb has to name what enrolment is for and what the passphrase costs,
    // and must carry no trace of the cutover tooling this surface grew out of.
    final blurb = tester.widget<Text>(find.byKey(const Key('enrolment_blurb'))).data!;
    expect(blurb, contains('before it can sync'));
    expect(blurb, contains('ceiling on your encryption'));
    expect(blurb, isNot(contains('Cutover')));
    expect(blurb, isNot(contains('#556')));
  });

  testWidgets('an account that already holds an escrow is joined, not founded',
      (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner(
        [
          _status(EnrolmentState.notEnrolled),
          _status(EnrolmentState.enrolled,
              memberId: 'member-2',
              founded: const ['workspace-default', 'workspace-preferences']),
        ],
        escrow: true,
      ),
    );

    expect(runner.escrowProbes, 1);
    expect(find.byKey(const Key('enrolment_state_join')), findsOneWidget);
    // Founding could only ever be refused for this account, so it is not drawn.
    expect(find.byKey(const Key('enrolment_generate_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_found_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_state_not_enrolled')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('enrolment_resume_field')),
      _generated,
    );
    await _tapScrolled(tester, const Key('enrolment_resume_button'));

    expect(runner.resumedWith, [_generated]);
    expect(find.byKey(const Key('enrolment_state_enrolled')), findsOneWidget);
  });

  testWidgets('an empty escrow slot opens the founding door', (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner([_status(EnrolmentState.notEnrolled)]),
    );

    expect(runner.escrowProbes, 1);
    expect(find.byKey(const Key('enrolment_state_not_enrolled')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_generate_button')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_state_join')), findsNothing);
  });

  testWidgets('an unreachable escrow probe offers a retry, not a guess',
      (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.notEnrolled)],
        escrowProbeFailure:
            const SyncTransportException.unreachable('no route to host'),
      ),
    );

    // Neither door can open offline, so the screen says so rather than drawing a
    // button whose only possible outcome is a failure.
    expect(
      tester
          .widget<Text>(find.byKey(const Key('enrolment_escrow_probe_error')))
          .data,
      allOf(contains('could not be checked'), contains('no route to host')),
    );
    expect(find.byKey(const Key('enrolment_generate_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_resume_button')), findsNothing);

    await _tapScrolled(tester, const Key('enrolment_escrow_probe_retry'));
    expect(runner.escrowProbes, 2);
  });

  testWidgets('an enrolled or half-founded device is never probed',
      (tester) async {
    final enrolled = await _pump(
      tester,
      _StubRunner([
        _status(EnrolmentState.enrolled,
            memberId: 'member-1',
            founded: const ['workspace-default', 'workspace-preferences']),
      ]),
    );
    expect(enrolled.escrowProbes, 0,
        reason: 'an enrolled store answers the question on its own');
  });

  testWidgets('the passphrase is shown, confirmed, then gone', (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner([
        _status(EnrolmentState.notEnrolled),
        _status(EnrolmentState.enrolled,
            memberId: 'member-1',
            founded: const ['workspace-default', 'workspace-preferences']),
      ]),
    );

    await _tapScrolled(tester, const Key('enrolment_generate_button'));
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('enrolment_passphrase'))).data,
      _generated,
    );
    // No clipboard affordance, ever: the passphrase is the encryption ceiling.
    expect(find.text('Copy'), findsNothing);
    expect(find.byIcon(Icons.copy), findsNothing);
    expect(find.byKey(const Key('enrolment_do_not_leave')), findsOneWidget);

    // AC 2: the explicit confirmation gates the ceremony, and it is asked before
    // the run so an interrupted one still leaves the phrase in hand.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('enrolment_found_button')))
          .onPressed,
      isNull,
    );
    await _tapScrolled(tester, const Key('enrolment_written_down_checkbox'));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('enrolment_found_button')))
          .onPressed,
      isNotNull,
    );

    await _tapScrolled(tester, const Key('enrolment_found_button'));

    expect(runner.foundedWith, [_generated]);
    // Shown exactly once: not in a field, not in a success echo, not anywhere.
    expect(find.byKey(const Key('enrolment_passphrase')), findsNothing);
    expect(find.text(_generated), findsNothing);
    expect(find.byKey(const Key('enrolment_state_enrolled')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('enrolment_member_id'))).data,
      contains('member-1'),
    );
    expect(find.byKey(const Key('enrolment_error')), findsNothing);
  });

  testWidgets('an enrolled device is offered no second founding', (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner([
        _status(EnrolmentState.enrolled,
            memberId: 'member-1',
            founded: const ['workspace-default', 'workspace-preferences']),
      ]),
    );

    expect(find.byKey(const Key('enrolment_state_enrolled')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_generate_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_found_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_resume_button')), findsNothing);
    expect(runner.generated, 0);
    // Both Workspaces are named with their state, which is the artifact the user
    // pastes back into the issue.
    expect(
      tester
          .widget<Text>(find.byKey(const Key('enrolment_workspace_workspace-preferences')))
          .data,
      contains('founded'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('enrolment_escrow_version'))).data,
      contains('1'),
    );
  });

  testWidgets('a half-founded device is offered the passphrase, not a founding',
      (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner([
        _status(EnrolmentState.foundingIncomplete, memberId: 'member-1'),
        _status(EnrolmentState.enrolled,
            memberId: 'member-1',
            founded: const ['workspace-default', 'workspace-preferences']),
      ]),
    );

    expect(
      find.byKey(const Key('enrolment_state_founding_incomplete')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('enrolment_do_not_leave')), findsOneWidget);
    expect(find.byKey(const Key('enrolment_generate_button')), findsNothing);
    expect(find.byKey(const Key('enrolment_found_button')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('enrolment_resume_field')),
      '  $_generated  ',
    );
    await _tapScrolled(tester, const Key('enrolment_resume_button'));

    // Trimmed: a passphrase transcribed off paper picks up whitespace, and the
    // words are what matter.
    expect(runner.resumedWith, [_generated]);
    expect(find.byKey(const Key('enrolment_state_enrolled')), findsOneWidget);
  });

  testWidgets('an unreachable server never tells the user to drop the phrase',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.notEnrolled)],
        foundFailure: const SyncTransportException.unreachable('no route'),
      ),
    );

    await _tapScrolled(tester, const Key('enrolment_generate_button'));
    await _tapScrolled(tester, const Key('enrolment_written_down_checkbox'));
    await _tapScrolled(tester, const Key('enrolment_found_button'));

    // "Unreachable" describes the request that failed, not the ceremony: the
    // escrow PUT is step 2 of 7, and a lost response to it is indistinguishable
    // here from one that never arrived. Telling the user nothing was written
    // would invite them to discard the one phrase that can finish the account.
    final error =
        tester.widget<Text>(find.byKey(const Key('enrolment_error'))).data!;
    expect(error, allOf(contains('unreachable'), contains('Keep this passphrase')));
    expect(error, isNot(contains('nothing was founded')));
    expect(find.byKey(const Key('enrolment_state_not_enrolled')), findsOneWidget);
    // The phrase stays on screen for the retry rather than being regenerated,
    // and the retry — not a resume field the store has no evidence for — is the
    // route offered: it is the retry's own 403 that reveals a landed escrow.
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('enrolment_passphrase'))).data,
      _generated,
    );
    expect(find.byKey(const Key('enrolment_resume_field')), findsNothing);
  });

  testWidgets('an escrow conflict offers the passphrase route', (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.notEnrolled)],
        foundFailure: const SyncTransportException(
          403,
          'escrow signature does not verify',
          code: badEscrowSignatureCode,
        ),
      ),
    );

    await _tapScrolled(tester, const Key('enrolment_generate_button'));
    await _tapScrolled(tester, const Key('enrolment_written_down_checkbox'));
    await _tapScrolled(tester, const Key('enrolment_found_button'));

    expect(
      tester.widget<Text>(find.byKey(const Key('enrolment_error'))).data,
      contains('An escrow already exists for this account'),
    );
    // The field is pre-wired with this session's phrase: it is the only copy that
    // exists, and a reload is exactly when it would be gone.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('enrolment_resume_field')))
          .controller!
          .text,
      _generated,
    );
    await _tapScrolled(tester, const Key('enrolment_resume_button'));
    expect(runner.resumedWith, [_generated]);
  });

  testWidgets('a correction typed into the resume field survives a failure',
      (tester) async {
    final runner = await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.notEnrolled)],
        foundFailure: const SyncTransportException(
          403,
          'escrow signature does not verify',
          code: badEscrowSignatureCode,
        ),
        resumeFailure: const RecoveryEscrowException(
          RecoveryEscrowFailure.wrongPassphrase,
          'did not authenticate',
        ),
      ),
    );

    await _tapScrolled(tester, const Key('enrolment_generate_button'));
    await _tapScrolled(tester, const Key('enrolment_written_down_checkbox'));
    await _tapScrolled(tester, const Key('enrolment_found_button'));

    // The phrase that actually claimed the escrow is the other device's, so the
    // pre-wired one is wrong and the user retypes. Re-wiring on the *next*
    // failure would silently hand back the phrase they just rejected, and they
    // would have to transcribe it off paper again.
    const String other = 'anvil ribbon staple battery horse correct';
    await tester.enterText(find.byKey(const Key('enrolment_resume_field')), other);
    await _tapScrolled(tester, const Key('enrolment_resume_button'));

    // Still offered, and still holding what they typed: the escrow conflict is
    // what revealed this route, and a mistyped phrase must not withdraw it.
    expect(runner.resumedWith, [other]);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('enrolment_resume_field')))
          .controller!
          .text,
      other,
    );
  });

  testWidgets('a wrong passphrase on resume is a prompt, not an alarm',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.foundingIncomplete, memberId: 'member-1')],
        resumeFailure: const RecoveryEscrowException(
          RecoveryEscrowFailure.wrongPassphrase,
          'did not authenticate',
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('enrolment_resume_field')),
      'six words that are simply not right',
    );
    await _tapScrolled(tester, const Key('enrolment_resume_button'));

    final error =
        tester.widget<Text>(find.byKey(const Key('enrolment_error'))).data!;
    expect(error, contains('did not open the escrow'));
    expect(error, contains('Nothing was changed'));
  });

  testWidgets('a substituted escrow alarms rather than prompting',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(
        [_status(EnrolmentState.foundingIncomplete, memberId: 'member-1')],
        resumeFailure: const RecoveryEscrowException(
          RecoveryEscrowFailure.rootMismatch,
          'not signed by the pinned Root',
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('enrolment_resume_field')),
      _generated,
    );
    await _tapScrolled(tester, const Key('enrolment_resume_button'));

    final error =
        tester.widget<Text>(find.byKey(const Key('enrolment_error'))).data!;
    expect(error, contains('not the one this device trusts'));
    expect(error, isNot(contains('did not open the escrow')));
  });

  testWidgets('a state that could not be read is reported, not blank',
      (tester) async {
    // Through `_pump` for its tall viewport: on the default surface the generate
    // button would be un-inflated rather than absent, and the assertion below
    // could not tell "no founding is offered" from "not built yet".
    await _pump(tester, _ThrowingRunner('sign in first'));

    expect(
      tester.widget<Text>(find.byKey(const Key('enrolment_status_error'))).data,
      contains('sign in first'),
    );
    expect(find.byKey(const Key('enrolment_generate_button')), findsNothing);
  });
}

class _ThrowingRunner implements EnrolmentCeremonyRunner {
  _ThrowingRunner(this.message);

  final String message;

  @override
  Future<EnrolmentCeremonyStatus> status() async => throw StateError(message);

  @override
  Future<bool> escrowExists() async => throw StateError(message);

  @override
  Future<String> generatePassphrase() async => throw StateError(message);

  @override
  Future<EnrolmentOutcome> found(String passphrase) async =>
      throw StateError(message);

  @override
  Future<EnrolmentOutcome> resume(String passphrase) async =>
      throw StateError(message);
}
