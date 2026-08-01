/// The enrolment ceremony surface (issues #586, #595, #673).
///
/// **Opt-in, and nothing routes here.** Enrolling is what starts sync, and the
/// user chooses when — from Settings' "Set up sync on this device", pushed so
/// the app bar's back arrow is a real way out. A signed-in device that never
/// comes here is not broken; it is a local-only device with an account, which is
/// a supported steady state.
///
/// Two presentations, chosen from the account rather than guessed: an account
/// whose recovery-escrow slot is empty is **founded** from here (generate a
/// passphrase, write it down, found); an account that already has an escrow is
/// **joined** with the passphrase from the device that founded it. A store that
/// says `notEnrolled` looks the same in both cases, which is why the screen
/// probes ([EnrolmentCeremonyRunner.escrowExists]) instead of offering a founding
/// the server could only refuse.
///
/// Deliberately plain — with two divergences that are not stylistic:
///
/// - **No copy-to-clipboard.** The passphrase is the ceiling on the account's
///   end-to-end encryption; a clipboard manager or a cloud clipboard sync would
///   carry it straight off the device. It is rendered large, monospaced and
///   selectable, to be transcribed onto paper.
/// - **`FLAG_SECURE` while this screen is mounted.** The recents thumbnail is a
///   capture of a show-once secret that the system takes without asking.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../services/secure_screen.dart';
import '../../sync/enrolment_state.dart';
import 'enrolment_ceremony_runner.dart';

class EnrolmentCeremonyScreen extends ConsumerStatefulWidget {
  const EnrolmentCeremonyScreen({super.key});

  static const String routePath = '/enrolment';

  @override
  ConsumerState<EnrolmentCeremonyScreen> createState() =>
      _EnrolmentCeremonyScreenState();
}

class _EnrolmentCeremonyScreenState
    extends ConsumerState<EnrolmentCeremonyScreen> {
  EnrolmentCeremonyStatus? _status;
  Object? _statusError;
  bool _loadingStatus = true;

  /// Whether the account's escrow slot is occupied — `null` while unknown,
  /// which after [_probingEscrow] clears means the probe could not reach the
  /// server. Founding and joining are both online operations, so an unknown
  /// answer is a retry rather than a guess.
  bool? _escrowExists;
  Object? _escrowProbeError;
  bool _probingEscrow = false;

  /// The generated passphrase, held for this screen's lifetime only.
  ///
  /// Cleared on a successful founding — the outcome's own echo of it is
  /// never rendered, so "shown exactly once" is what the widget tree says and
  /// not just what the copy claims. Kept after a *failure*, because a ceremony
  /// that stopped half way is resumed with this exact phrase and nothing else.
  String? _passphrase;

  /// The user's explicit "I wrote it down", which gates founding (AC 2). Asked
  /// *before* the ceremony runs, so an interrupted run still leaves the phrase in
  /// hand.
  bool _writtenDown = false;

  bool _running = false;
  Object? _error;
  EnrolmentCeremonyFailure? _failure;

  /// Whether an attempt in this session hit an escrow that already exists.
  ///
  /// Sticky, unlike [_failure]: the escrow conflict is what reveals the resume
  /// route on a device the store still reads as un-enrolled, and the next failure
  /// — a mistyped passphrase, most likely — must not take that route away again.
  bool _escrowConflictSeen = false;

  final TextEditingController _resumeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Before the first frame, not after the passphrase exists: the flag has to be
    // on the window when the system next thumbnails the task, whenever that is.
    setSecureScreen(secure: true);
    _loadStatus();
  }

  @override
  void dispose() {
    // Window-scoped, so leaving without clearing it would silently make every
    // later screen unscreenshottable.
    setSecureScreen(secure: false);
    _resumeController.dispose();
    super.dispose();
  }

  EnrolmentCeremonyRunner get _runner =>
      ref.read(enrolmentCeremonyRunnerProvider);

  Future<void> _loadStatus() async {
    setState(() => _loadingStatus = true);
    try {
      final status = await _runner.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _statusError = null;
        _loadingStatus = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = null;
        _statusError = error;
        _loadingStatus = false;
      });
      return;
    }
    // Only `notEnrolled` is ambiguous. `foundingIncomplete` already knows the
    // escrow landed, and `enrolled` is terminal.
    if (_status?.state == EnrolmentState.notEnrolled) await _probeEscrow();
  }

  /// Ask the account whether it has been founded already, so the screen offers
  /// the one door that can actually open.
  Future<void> _probeEscrow() async {
    setState(() {
      _probingEscrow = true;
      _escrowProbeError = null;
    });
    try {
      final exists = await _runner.escrowExists();
      if (!mounted) return;
      setState(() {
        _escrowExists = exists;
        _probingEscrow = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _escrowExists = null;
        _escrowProbeError = error;
        _probingEscrow = false;
      });
    }
  }

  Future<void> _generate() async {
    try {
      final passphrase = await _runner.generatePassphrase();
      if (!mounted) return;
      setState(() {
        _passphrase = passphrase;
        _writtenDown = false;
        _error = null;
        _failure = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _failure = classifyEnrolmentCeremonyFailure(error);
      });
    }
  }

  /// One attempt, whichever it is. The outcome is never read: it echoes the
  /// passphrase, and the enrolled panel is re-read from the store instead.
  Future<void> _run(Future<void> Function() attempt) async {
    setState(() {
      _running = true;
      _error = null;
      _failure = null;
    });
    Object? failure;
    try {
      await attempt();
    } catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = failure;
      _failure = failure == null ? null : classifyEnrolmentCeremonyFailure(failure);
      if (_failure == EnrolmentCeremonyFailure.escrowAlreadyExists) {
        _escrowConflictSeen = true;
      }
      if (failure == null) {
        // Shown exactly once: the phrase leaves the widget tree the moment the
        // ceremony it protected succeeded.
        _passphrase = null;
        _writtenDown = false;
        _escrowConflictSeen = false;
        _resumeController.clear();
      } else if (_passphrase != null && _resumeController.text.isEmpty) {
        // Pre-wire the resume field with the phrase this session generated, so a
        // failure after the escrow landed is one tap from recovery. Only into an
        // empty field: every failed attempt comes through here, and overwriting
        // would throw away a correction — or another device's phrase — the user
        // typed before the attempt that just failed.
        _resumeController.text = _passphrase!;
      }
    });
    // Always re-read: what is on screen has to be the store's truth rather than
    // the last attempt's hope, and the resume affordance is chosen from it.
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enrolment ceremony'),
        actions: [
          // Not an escape hatch any more — backing out is what the app bar's
          // arrow does. This is the fresh-signup path: a user who opened the
          // ceremony and found the wrong account on it enrols a different one
          // from here without going hunting through Settings.
          IconButton(
            key: const Key('enrolment_sign_out'),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: _running
                ? null
                : () => ref.read(authTokenProvider.notifier).logout(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This device has to be enrolled before it can sync. Founding a new '
            'account generates a recovery passphrase, mints a Root key and '
            'escrows it under that passphrase, registers this device, and writes '
            'each Workspace\'s genesis plus this device\'s owner grant; joining '
            'an account that already exists takes the passphrase instead. The '
            'passphrase is the ceiling on your encryption — anyone who guesses '
            'it can read your data, and nobody, including us, can reset it for '
            'you.',
            key: Key('enrolment_blurb'),
          ),
          const SizedBox(height: 16),
          if (_loadingStatus)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(
                  key: Key('enrolment_status_loading'),
                ),
              ),
            ),
          if (_statusError != null)
            Text(
              'This device\'s enrolment state could not be read: $_statusError',
              key: const Key('enrolment_status_error'),
            ),
          if (status != null) ..._forStatus(status),
          if (_running) ..._runningBlock(),
          if (_error != null && !_running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                enrolmentCeremonyFailureMessage(_failure!, _error!),
                key: const Key('enrolment_error'),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _runningBlock() => const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: CircularProgressIndicator(key: Key('enrolment_running')),
          ),
        ),
        Text(
          'Deriving the escrow key and founding the Workspaces. This takes a few '
          'seconds.',
          key: Key('enrolment_running_note'),
        ),
      ];

  List<Widget> _forStatus(EnrolmentCeremonyStatus status) =>
      switch (status.state) {
        EnrolmentState.enrolled => _enrolledBlock(status),
        EnrolmentState.foundingIncomplete => _foundingIncompleteBlock(status),
        EnrolmentState.notEnrolled => _notEnrolledBlock(),
      };

  /// The terminal state. **No founding control of any kind** (AC 3): a second
  /// founding is refused below the UI as well, but the screen must not offer it.
  List<Widget> _enrolledBlock(EnrolmentCeremonyStatus status) => [
        const Text(
          'Enrolled. This device holds its keys, a pinned Root and a member '
          'credential, and both Workspaces are founded.',
          key: Key('enrolment_state_enrolled'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text('Member id: ${status.memberId}',
            key: const Key('enrolment_member_id')),
        Text('Escrow version: ${status.escrowVersion}',
            key: const Key('enrolment_escrow_version')),
        Text('Root fingerprint: ${status.rootPkFingerprint}',
            key: const Key('enrolment_root_fingerprint')),
        const SizedBox(height: 8),
        for (final workspaceId in status.workspaceIds)
          Text(
            'Workspace $workspaceId — '
            '${status.foundedWorkspaceIds.contains(workspaceId) ? 'founded' : 'not founded'}',
            key: Key('enrolment_workspace_$workspaceId'),
          ),
      ];

  /// A crash window. Two shapes reach here and both recover the same way, so the
  /// screen says the same thing for both: the passphrase, and only it, finishes
  /// this.
  List<Widget> _foundingIncompleteBlock(EnrolmentCeremonyStatus status) => [
        const Text(
          'Half-founded. A ceremony on this device already claimed this '
          'account\'s recovery escrow and did not finish, so founding again '
          'cannot work — the escrow is not this device\'s to replace. Enter the '
          'passphrase from that attempt to finish it.',
          key: Key('enrolment_state_founding_incomplete'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _doNotLeaveWarning,
        const SizedBox(height: 8),
        if (status.memberId != null)
          Text('Member id: ${status.memberId}',
              key: const Key('enrolment_member_id')),
        if (status.rootPkFingerprint != null)
          Text('Root fingerprint: ${status.rootPkFingerprint}',
              key: const Key('enrolment_root_fingerprint')),
        const SizedBox(height: 8),
        ..._resumeControls(),
      ];

  /// The un-enrolled device, split by what the account's escrow slot says.
  ///
  /// Three shapes, and the ordering of the guards is the whole rule: an occupied
  /// slot means founding is impossible, so it is not offered; an unreachable
  /// probe means *neither* path can proceed, so a retry is offered instead of a
  /// button that would fail — **unless** a passphrase from an earlier attempt is
  /// still on screen, in which case hiding the block would take the only copy of
  /// it with it.
  List<Widget> _notEnrolledBlock() {
    if (_probingEscrow) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: CircularProgressIndicator(
              key: Key('enrolment_escrow_probe_loading'),
            ),
          ),
        ),
      ];
    }
    if (_escrowExists == true) return _joinBlock();
    if (_escrowExists == null && _passphrase == null) return _probeFailedBlock();
    return _foundBlock();
  }

  /// The account already holds an escrow: this device joins it with the
  /// passphrase the founding device wrote down. No founding control at all — the
  /// escrow PUT is not this device's to make, and the server would refuse it.
  List<Widget> _joinBlock() => [
        const Text(
          'This account has already been founded. Enter the recovery passphrase '
          'from the device that founded it to enrol this one.',
          key: Key('enrolment_state_join'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ..._resumeControls(),
      ];

  /// The probe could not reach the server. Honest rather than optimistic:
  /// founding and joining both need the network, so there is nothing to offer
  /// but a retry.
  List<Widget> _probeFailedBlock() => [
        Text(
          'This account\'s enrolment could not be checked: $_escrowProbeError. '
          'Both founding this account and joining an existing one need the '
          'server, so there is nothing to do offline — try again once you have '
          'a connection.',
          key: const Key('enrolment_escrow_probe_error'),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('enrolment_escrow_probe_retry'),
          onPressed: _probingEscrow ? null : _loadStatus,
          child: const Text('Try again'),
        ),
      ];

  List<Widget> _foundBlock() {
    final passphrase = _passphrase;
    return [
      const Text(
        'Not enrolled. Nothing has been written for this account yet.',
        key: Key('enrolment_state_not_enrolled'),
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      if (passphrase == null)
        FilledButton(
          key: const Key('enrolment_generate_button'),
          onPressed: _running ? null : _generate,
          child: const Text('Generate passphrase'),
        ),
      if (passphrase != null) ...[
        const Text(
          'Write these six words down on paper, in this order. They will not be '
          'shown again, they cannot be recovered, and there is deliberately no '
          'copy button — a clipboard is the one place this must never go.',
          key: Key('enrolment_passphrase_instructions'),
        ),
        const SizedBox(height: 12),
        SelectableText(
          passphrase,
          key: const Key('enrolment_passphrase'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 20,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        _doNotLeaveWarning,
        CheckboxListTile(
          key: const Key('enrolment_written_down_checkbox'),
          value: _writtenDown,
          onChanged: _running
              ? null
              : (value) => setState(() => _writtenDown = value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'I have written this passphrase down — it will never be shown again',
          ),
        ),
        FilledButton(
          key: const Key('enrolment_found_button'),
          onPressed: _writtenDown && !_running
              ? () => _run(() => _runner.found(passphrase))
              : null,
          child: const Text('Found the Workspace'),
        ),
        // A ceremony that failed *after* the escrow landed leaves this device
        // half-founded, and the phrase above is what finishes it. Offered here
        // rather than only after a reload, because the reload is exactly when the
        // phrase would be gone.
        if (_escrowConflictSeen) ..._resumeControls(),
      ],
    ];
  }

  List<Widget> _resumeControls() => [
        TextField(
          key: const Key('enrolment_resume_field'),
          controller: _resumeController,
          enabled: !_running,
          minLines: 1,
          maxLines: 2,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Recovery passphrase',
            helperText: 'The six words from the attempt that claimed the escrow.',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('enrolment_resume_button'),
          onPressed: _running
              ? null
              : () {
                  final typed = _resumeController.text.trim();
                  if (typed.isEmpty) return;
                  _run(() => _runner.resume(typed));
                },
          child: const Text('Enrol with the passphrase'),
        ),
      ];

  static const Widget _doNotLeaveWarning = Text(
    'Do not leave this screen until it says enrolled — the passphrase is not '
    'recoverable, and a ceremony interrupted after the escrow is written can '
    'only be finished with it.',
    key: Key('enrolment_do_not_leave'),
    style: TextStyle(fontWeight: FontWeight.w600),
  );
}
