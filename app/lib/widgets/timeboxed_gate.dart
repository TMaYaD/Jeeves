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

import '../models/timeboxed.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import '../providers/timeboxed_limit_provider.dart';
import 'meta_chip.dart' show formatMinutesLabel;
import 'outcome_attribute_editors.dart';
import 'timeboxed_limit_strip.dart';

/// What the user chose at the gate.
enum TimeboxedGateChoice {
  /// "Right ho" — the Sprint starts.
  start,

  /// "Another sprint, regardless", confirmed a second time — the Sprint
  /// starts and the estimate is left exactly as it was.
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
  return showModalBottomSheet<TimeboxedGateChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
    ),
    builder: (_) =>
        _TimeboxedGateSheet(actionText: actionText, status: status, now: now),
  );
}

/// Runs [start], unless the Outcome's current Action is Timeboxed and its
/// limit has already been passed — in which case Jeeves advises first and the
/// user confirms.
///
/// "Right ho" starts the Sprint. "Another sprint, regardless" asks once more
/// and then starts it, leaving the estimate exactly as it was. "Raise the
/// estimate…" opens the estimate sheet, and if the raised estimate moves the
/// limit out of the way the Sprint starts after all; if it does not, the
/// Sprint does not start. Nothing here is locked.
Future<void> guardSprintPastLimit(
  BuildContext context,
  WidgetRef ref, {
  required String outcomeId,
  required Future<void> Function() start,
}) async {
  final db = ref.read(databaseProvider);
  final status = await readTimeboxedLimitStatus(db, outcomeId);
  if (status == null) {
    await start();
    return;
  }
  final now = DateTime.now().toUtc();
  if (!status.hasPassedAt(now)) {
    await start();
    return;
  }
  final action = await db.actionDao.getCurrentAction(outcomeId);
  if (!context.mounted) return;
  final choice = await showTimeboxedSprintGate(
    context,
    actionText: action?.actionText ?? '',
    status: status,
    now: now,
  );
  if (choice == TimeboxedGateChoice.start ||
      choice == TimeboxedGateChoice.regardless) {
    await start();
    return;
  }
  if (choice != TimeboxedGateChoice.raise) return;

  if (!context.mounted) return;
  await _raiseTheEstimate(context, ref, outcomeId: outcomeId);

  // A raised estimate moves the limit with it. If the limit is no longer
  // passed, the Sprint starts after all; if it is still passed, it does not.
  final after = await readTimeboxedLimitStatus(db, outcomeId);
  if (after == null || !after.hasPassedAt(now)) {
    await start();
  }
}

/// Opens the estimate sheet for [outcomeId]'s current Action.
///
/// The change is permanent, which is what the gate promises; raising the
/// estimate clears the Timeboxed switch only if the estimate is cleared
/// altogether (the estimate sheet's own rule).
Future<void> _raiseTheEstimate(
  BuildContext context,
  WidgetRef ref, {
  required String outcomeId,
}) async {
  final db = ref.read(databaseProvider);
  final action = await db.actionDao.getCurrentAction(outcomeId);
  if (action == null) return;
  final notifier = ref.read(taskDetailNotifierProvider(outcomeId));
  if (!context.mounted) return;
  await showOutcomeTimeEstimateSheet(
    context,
    notifier,
    current: action.timeEstimate,
    actionText: action.actionText,
    actionId: action.id,
    timeboxed: action.timeboxed ?? false,
  );
}

/// The gate sheet: what has happened, Jeeves' advice, and the ways on.
class _TimeboxedGateSheet extends StatefulWidget {
  const _TimeboxedGateSheet({
    required this.actionText,
    required this.status,
    required this.now,
  });

  /// The Action's text — what the Sprint would run on.
  final String actionText;

  /// The limit status, read at the moment the gate opened.
  final TimeboxedLimitStatus status;

  /// The instant the gate opened.
  final DateTime now;

  @override
  State<_TimeboxedGateSheet> createState() => _TimeboxedGateSheetState();
}

class _TimeboxedGateSheetState extends State<_TimeboxedGateSheet> {
  /// Whether the user has already asked to carry on regardless; the sheet
  /// asks once more before it starts the Sprint.
  bool _askedAgain = false;

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
              'Nothing is locked. Carrying on leaves the estimate as it is; '
              'raising it is permanent, and the rest of the day is re-flowed '
              'around it.',
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

  /// The first ask: Jeeves advises, and the user may start, carry on
  /// regardless, or raise the estimate.
  List<Widget> _firstAsk(TimeboxedAdvice advice) {
    return [
      _jeevesPair(advice),
      const SizedBox(height: 14),
      FilledButton(
        key: const Key('timeboxed_gate_start'),
        onPressed: () => Navigator.of(context).pop(TimeboxedGateChoice.start),
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
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            key: const Key('timeboxed_gate_cancel'),
            onPressed: () =>
                Navigator.of(context).pop(TimeboxedGateChoice.cancel),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF6B7280),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            child: const Text('Never mind'),
          ),
          TextButton(
            key: const Key('timeboxed_gate_raise'),
            onPressed: () =>
                Navigator.of(context).pop(TimeboxedGateChoice.raise),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF2667B7),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            child: const Text('Raise the estimate…'),
          ),
        ],
      ),
    ];
  }

  /// The second ask: "regardless" is confirmed once, and then the Sprint
  /// starts with the estimate untouched.
  List<Widget> _secondAsk() {
    return [
      _jeevesPair(
        const TimeboxedAdvice(
          headline: 'Quite so, sir.',
          detail:
              'Nothing is locked, but the estimate will not move of its '
              'own accord.',
        ),
      ),
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
        child: const Text('Very good'),
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
