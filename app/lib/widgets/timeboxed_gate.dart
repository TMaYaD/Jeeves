/// The gate before a Sprint started past a Timeboxed limit (issue #923).
///
/// Nothing is locked. Jeeves advises, and the user chooses: carry on, carry
/// on regardless (asked once more, then it starts), or raise the estimate,
/// which moves the limit with it and for good.
///
/// The gate reads the limit fresh rather than trusting a cached value: a
/// Sprint can pass the limit while nobody is looking at the surface that
/// would have shown it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/estimate.dart';
import '../models/timeboxed.dart';
import '../providers/clock_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import '../providers/timeboxed_limit_provider.dart';
import 'meta_chip.dart' show formatMinutesLabel;
import 'outcome_attribute_editors.dart';
import 'timeboxed_limit_strip.dart';

/// What the user chose at the gate.
enum TimeboxedGateChoice {
  /// "Right ho" — the sheet closes and the Sprint does not start. Nothing is
  /// written: the user stays where they were.
  stop,

  /// "Yes, another sprint" — confirmed a second time; the Sprint starts and
  /// the estimate is left exactly as it was.
  regardless,

  /// "Raise the estimate…" — the estimate sheet was opened; a raised
  /// estimate moves the limit with it.
  raise,

  /// "Never mind" — the Sprint does not start.
  cancel,
}

/// Shows the gate, and returns what the user chose.
///
/// Null when the sheet was dismissed without a choice — which is a cancel.
Future<TimeboxedGateChoice?> showTimeboxedSprintGate(
  BuildContext context, {
  required String actionText,
  required TimeboxedLimitStatus status,
  required DateTime now,
}) {
  if (_gateSheetOpen) return Future.value(null);
  _gateSheetOpen = true;
  final sheetId = ++_openGateSheetId;
  return showModalBottomSheet<TimeboxedGateChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) => _TimeboxedGateSheet(
      actionText: actionText,
      status: status,
      now: now,
      onClosed: () => _closeGateSheet(sheetId),
    ),
  ).whenComplete(() {
    _closeGateSheet(sheetId);
  });
}

/// Whether a gate sheet is already up.
///
/// Two quick taps on Start would otherwise open two sheets, and the second
/// one's answer would start the Sprint behind the first.
bool _gateSheetOpen = false;

/// Which sheet is the open one.
///
/// A sheet clears the flag when it is disposed, not when its future
/// completes: a sheet dismissed without a choice never completes that future,
/// and the gate would then be shut for good. The id keeps a sheet that is on
/// its way out from clearing the flag of the sheet that replaced it.
int _openGateSheetId = 0;

/// Clears the flag, unless a later sheet has taken over.
void _closeGateSheet(int sheetId) {
  if (sheetId != _openGateSheetId) return;
  _gateSheetOpen = false;
}

/// Runs [start], unless the Outcome's current Action is Timeboxed and its
/// limit has already been passed — in which case Jeeves advises first and the
/// user chooses.
///
/// "Right ho" starts nothing: the sheet closes and the user stays where they
/// were. "Another sprint, regardless" asks once more and then starts the
/// Sprint, leaving the estimate exactly as it was. "Raise the estimate…"
/// opens the estimate sheet one step up; if the raised estimate moves the
/// limit out of the way the Sprint starts after all, and if it does not, the
/// gate asks again with the figures as they now stand. Nothing here is
/// locked.
Future<void> guardSprintPastLimit(
  BuildContext context,
  WidgetRef ref, {
  required String outcomeId,
  required Future<void> Function() start,
}) async {
  // The screen may already be gone: there is nothing to read the limit for,
  // and nothing to start the Sprint from.
  if (!context.mounted) return;
  final db = ref.read(databaseProvider);
  final initial = await readTimeboxedLimitStatus(db, outcomeId);
  // The screen may have gone while the status was being read. Starting the
  // Sprint then would reach through a screen that is no longer there.
  if (!context.mounted) return;
  if (initial == null) {
    await start();
    return;
  }
  var now = ref.read(clockProvider)().toUtc();
  if (!initial.hasPassedAt(now)) {
    await start();
    return;
  }
  var status = initial;
  var action = await db.actionDao.getCurrentAction(outcomeId);
  // The sheet names the Outcome, as the design does; the Action's own text is
  // the fallback for an Outcome whose title has gone.
  final todo = await db.todoDao.getTodo(outcomeId);
  if (!context.mounted) return;
  var choice = await showTimeboxedSprintGate(
    context,
    actionText: todo?.title ?? action?.actionText ?? '',
    status: status,
    now: now,
  );
  if (!context.mounted) return;
  // "Raise the estimate…" opens the estimate sheet. Whatever happens there —
  // saved or cancelled — the gate asks again with the figures as they now
  // stand, so the user is never left without a way on.
  while (choice == TimeboxedGateChoice.raise) {
    if (!context.mounted) return;
    final saved = await _raiseTheEstimate(context, ref, outcomeId: outcomeId);
    if (!context.mounted) return;
    if (saved) {
      // A raised estimate moves the limit with it. If the limit is no longer
      // passed, the Sprint starts after all; if it is still passed, the gate
      // asks again with the new figures.
      final after = await readTimeboxedLimitStatus(db, outcomeId);
      if (!context.mounted) return;
      // The clock is read after the status is loaded: the read takes a
      // moment, and a limit that passed during it must still ask.
      now = ref.read(clockProvider)().toUtc();
      if (after == null || !after.hasPassedAt(now)) {
        await start();
        return;
      }
      status = after;
      action = await db.actionDao.getCurrentAction(outcomeId);
      if (!context.mounted) return;
    } else {
      // The estimate sheet was open for a while, and the limit may have passed
      // while it was. The figures the sheet shows are counted from this
      // instant.
      now = ref.read(clockProvider)().toUtc();
    }
    choice = await showTimeboxedSprintGate(
      context,
      actionText: todo?.title ?? action?.actionText ?? '',
      status: status,
      now: now,
    );
    if (!context.mounted) return;
  }
  if (choice == TimeboxedGateChoice.regardless) {
    await start();
  }
}

/// Opens the estimate sheet for [outcomeId]'s current Action, one step above
/// the estimate it has.
///
/// Returns whether the sheet was saved. The change is permanent, which is what
/// the gate promises; raising the estimate clears the Timeboxed switch only if
/// the estimate is cleared altogether (the estimate sheet's own rule).
Future<bool> _raiseTheEstimate(
  BuildContext context,
  WidgetRef ref, {
  required String outcomeId,
}) async {
  final db = ref.read(databaseProvider);
  final action = await db.actionDao.getCurrentAction(outcomeId);
  if (action == null) return false;
  if (!context.mounted) return false;
  final notifier = ref.read(taskDetailNotifierProvider(outcomeId));
  return showOutcomeTimeEstimateSheet(
    context,
    notifier,
    current: action.timeEstimate,
    // One step up the ladder: the sheet opens on the raised value, so the
    // user confirms it rather than reaching for it.
    initial: stepEstimateUp(action.timeEstimate),
    actionText: action.actionText,
    actionId: action.id,
    // The switch reads as the limit does: on only when there is an estimate
    // to limit.
    timeboxed: isTimeboxedAction(
      timeboxed: action.timeboxed,
      timeEstimate: action.timeEstimate,
    ),
  );
}

/// The gate sheet: what has happened, Jeeves' advice, and the ways on.
class _TimeboxedGateSheet extends StatefulWidget {
  const _TimeboxedGateSheet({
    required this.actionText,
    required this.status,
    required this.now,
    required this.onClosed,
  });

  /// The Action's text — what the Sprint would run on.
  final String actionText;

  /// The limit status, read at the moment the gate opened.
  final TimeboxedLimitStatus status;

  /// The instant the gate opened.
  final DateTime now;

  /// Called when the sheet is disposed — however it went.
  final VoidCallback onClosed;

  @override
  State<_TimeboxedGateSheet> createState() => _TimeboxedGateSheetState();
}

class _TimeboxedGateSheetState extends State<_TimeboxedGateSheet> {
  /// Whether the user has already asked to carry on regardless; the sheet
  /// asks once more before it starts the Sprint.
  bool _askedAgain = false;

  @override
  void dispose() {
    // The sheet is gone, whatever happened to it: the gate is open again.
    widget.onClosed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final pastMinutes = status.minutesPast(widget.now);
    final pastSprints = status.sprintsPastLimit;
    final advice = timeboxedAdviceFor(pastSprints + 1);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.actionText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 10),
            TimeboxedLimitStrip(
              headline: '${formatMinutesLabel(pastMinutes)} past the limit',
              detail: 'Sprints past the limit so far: $pastSprints',
            ),
            const SizedBox(height: 12),
            if (_askedAgain) ..._secondAsk() else ..._firstAsk(advice),
            const SizedBox(height: 10),
            const Text(
              '“Regardless” asks once more, then starts. Nothing is locked. '
              '“Regardless” leaves the estimate as it is. Raising it is '
              'permanent.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF6B7280),
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The first ask: Jeeves advises, and the user may stop, carry on
  /// regardless, or raise the estimate.
  ///
  /// "Right ho" puts stopping first, as the design does: it closes the sheet
  /// and the Sprint does not start. "Another sprint, regardless" is the way
  /// on, and it asks once more before it starts anything.
  List<Widget> _firstAsk(TimeboxedAdvice advice) {
    return [
      _jeevesPair(advice),
      const SizedBox(height: 14),
      FilledButton(
        key: const Key('timeboxed_gate_stop'),
        onPressed: () => Navigator.of(context).pop(TimeboxedGateChoice.stop),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF2667B7),
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
        ),
        child: const Text('Right ho'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const Key('timeboxed_gate_regardless'),
        onPressed: () => setState(() => _askedAgain = true),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF1A1A2E),
          minimumSize: const Size.fromHeight(48),
        ),
        child: const Text('Another sprint, regardless'),
      ),
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('timeboxed_gate_raise'),
          onPressed: () =>
              Navigator.of(context).pop(TimeboxedGateChoice.raise),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF2667B7),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          child: const Text('Raise the estimate…'),
        ),
      ),
    ];
  }

  /// The second ask: "regardless" is confirmed once, and then the Sprint
  /// starts with the estimate untouched.
  List<Widget> _secondAsk() {
    return [
      _jeevesLine('Once more, sir, to be certain.'),
      const SizedBox(height: 14),
      FilledButton(
        key: const Key('timeboxed_gate_confirm'),
        onPressed: () =>
            Navigator.of(context).pop(TimeboxedGateChoice.regardless),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF2667B7),
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
        ),
        child: const Text('Yes, another sprint'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        key: const Key('timeboxed_gate_cancel'),
        onPressed: () => Navigator.of(context).pop(TimeboxedGateChoice.cancel),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF1A1A2E),
          minimumSize: const Size.fromHeight(48),
        ),
        child: const Text('Never mind'),
      ),
    ];
  }

  /// Jeeves' one line: the bold voice, with nothing under it.
  Widget _jeevesLine(String headline) {
    return Text(
      headline,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1A1A2E),
        height: 1.25,
      ),
    );
  }

  /// Jeeves' pair: the bold line over the quieter one.
  Widget _jeevesPair(TimeboxedAdvice advice) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          advice.headline,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
            height: 1.25,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          advice.detail,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF4A5568),
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
