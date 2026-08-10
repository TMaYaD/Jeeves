/// The re-clarification prompt floated when a Focus session's **Done** button
/// completes the current Action (issue #469).
///
/// Pressing Done in the focus session marks the current *Action* done — an
/// engagement signal, not a declaration that the *Outcome* is achieved
/// (CONTEXT.md § GTD Core). The Outcome enters the no-current-Action state;
/// rather than silently waiting for the next Daily Planning review, this sheet
/// floats immediately with execution-context copy ("strike while the iron is
/// hot — record what's next while context is fresh"). It is an explicit clarify
/// act deliberately interspersed into execution time, not a violation of the
/// no-clarify-at-execute-time principle.
///
/// The verdict surface is the canonical [ProcessToHandlers] bar over an
/// [OutcomeSubject], with `trash` excluded — leaving exactly the four ruled
/// verdicts: **Outcome achieved** (records the Outcome's Completion),
/// **More to do…** (opens [NextActionDialog], which offers the Outcome's
/// planned queue for one-tap promotion, or an empty field to name a new Action
/// when there is no queue — issue #723), **Waiting on someone…**, and **Defer
/// to Someday**. The writes are owned by [ProcessToHandlers] /
/// [ClarificationService]; this widget is only the sheet shell.
///
/// Dismissing the sheet (barrier tap / swipe) resolves to `null` and writes
/// nothing: the Outcome stays Actionless and un-stamped, so it surfaces in the
/// next DPR's review step (`TodoDao.getNeedsReview`).
library;

import 'package:flutter/material.dart';

import '../database/gtd_database.dart';
import 'process_to_handlers.dart';

class ReclarifyPromptSheet extends StatelessWidget {
  const ReclarifyPromptSheet({super.key, required this.todo});

  final Todo todo;

  /// Floats the re-clarify prompt for [todo]. Resolves to the chosen
  /// [ProcessAction] once a verdict commits, or `null` when the user dismisses
  /// the sheet without choosing one.
  static Future<ProcessAction?> show(BuildContext context, Todo todo) {
    return showModalBottomSheet<ProcessAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        // Sheets sit at 6px on the canonical 2/4/6 scale (DESIGN.md §Roundedness).
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (_) => ReclarifyPromptSheet(todo: todo),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Re-clarify outcome',
      container: true,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle for affordance.
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              // Header: names the just-finished *Action*, disambiguating from
              // the Outcome-Done verdict below (and #457's shutdown Done).
              const Text(
                'Action complete',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "While it's fresh — where does '${todo.title}' stand now?",
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 16),
              // The canonical verdict bar, minus Trash. `nextActionDialog`
              // stays on (default), and no `currentActionText` is passed, so
              // "More to do…" opens the next-action dialog with no prefilled
              // phrase — but it offers the Outcome's planned queue for one-tap
              // promotion when there is one (issue #723). The current Action's
              // cursor was already cleared by `completeCurrentAction`.
              ProcessToHandlers(
                subject: OutcomeSubject(todo),
                except: const {ProcessAction.trash},
                labels: const {
                  // The one branch that records an Outcome Completion — same
                  // green `task_alt` icon as every other Outcome-Done
                  // affordance. Plain "Done" here would recreate the
                  // Action/Outcome conflation this flow removes.
                  ProcessAction.done: 'Outcome achieved',
                  ProcessAction.next: 'More to do…',
                  ProcessAction.waitingFor: 'Waiting on someone…',
                  ProcessAction.someday: 'Defer to Someday',
                },
                onAfterRoute: (action) async {
                  // onAfterRoute runs after the routing write is awaited, so
                  // the sheet's context may already be deactivated. Guard
                  // before touching the Navigator — an unmounted context leaves
                  // the sheet gone and nothing left to pop.
                  if (!context.mounted) return;
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop(action);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
