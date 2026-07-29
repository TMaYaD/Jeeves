/// The enrolment ceremony surface over a scripted runner.
///
/// Cutover tooling — removed by #556.
///
/// What is asserted here is what the screen is *for*: the passphrase is shown
/// once and confirmed before anything runs, an enrolled device is offered no
/// second founding, a half-founded one is offered the passphrase, every failure
/// says what it left behind — and the window carries `FLAG_SECURE` while the
/// secret is on it. The ceremony itself is
/// `test/sync/enrolment_ceremony_runner_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/cutover/enrolment_ceremony/enrolment_ceremony_runner.dart';
import 'package:jeeves/cutover/enrolment_ceremony/enrolment_ceremony_screen.dart';
import 'package:jeeves/services/secure_screen.dart';
import 'package:jeeves/sync/enrolment.dart';
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
  _StubRunner(this._statuses, {this.foundFailure, this.resumeFailure});

  final List<EnrolmentCeremonyStatus> _statuses;
  final Object? foundFailure;
  final Object? resumeFailure;

  int statusReads = 0;
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

Future<_StubRunner> _pump(WidgetTester tester, _StubRunner runner) async {
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
    // The blurb has to name both the #556 fate and what the passphrase costs.
    final blurb = tester.widget<Text>(find.byKey(const Key('enrolment_blurb'))).data!;
    expect(blurb, contains('removed once the sync pivot lands'));
    expect(blurb, contains('ceiling on your encryption'));
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

  testWidgets('an unreachable server says nothing was founded', (tester) async {
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

    expect(
      tester.widget<Text>(find.byKey(const Key('enrolment_error'))).data,
      allOf(contains('unreachable'), contains('nothing was founded')),
    );
    expect(find.byKey(const Key('enrolment_state_not_enrolled')), findsOneWidget);
    // Still un-enrolled, so founding stays on offer — with a fresh phrase.
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          enrolmentCeremonyRunnerProvider
              .overrideWithValue(_ThrowingRunner('sign in first')),
        ],
        child: const MaterialApp(home: EnrolmentCeremonyScreen()),
      ),
    );
    await tester.pumpAndSettle();

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
  Future<String> generatePassphrase() async => throw StateError(message);

  @override
  Future<EnrolmentOutcome> found(String passphrase) async =>
      throw StateError(message);

  @override
  Future<EnrolmentOutcome> resume(String passphrase) async =>
      throw StateError(message);
}
