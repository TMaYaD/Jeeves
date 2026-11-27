/// The Focus session's advance: which task comes next, what the transition
/// says, and the snackbar that carries it.
///
/// These live apart from the Active Focus screen because several surfaces read
/// them: the Active Focus screen itself, and the places a Timeboxed gate can
/// stop an approach and leave the user somewhere to carry on from (issue #49).
library;

import 'package:flutter/material.dart';

import '../database/daos/focus_session_dao.dart' show SessionSettlement;
import '../database/gtd_database.dart' show Todo;
import 'process_to_handlers.dart' show ProcessAction;

/// The focus-list transition message shown after a Focus "Done" verdict
/// resolves.
///
/// "All done for today!" is claimed **only** on a genuine achieved-and-last
/// verdict. This keys on the achieved verdict specifically
/// ([ProcessAction.done]), not on any truthy resolution: every "More to do"
/// save resolves as [ProcessAction.nextActionDialog] — whether the user typed a
/// phrase or left it empty and took the title-as-action fallback — and neither
/// achieves the Outcome, so neither may claim "All done". A `null` verdict
/// (the prompt was dismissed) is likewise not an achievement.
///
/// [stoppedAtLimit] says the approach was stopped at its Timeboxed limit
/// rather than completed (issue #49), and the message says so.
String focusAdvanceMessage({
  required Todo? nextTask,
  required ProcessAction? verdict,
  bool stoppedAtLimit = false,
}) {
  if (nextTask != null) {
    return stoppedAtLimit
        ? 'Stopped there. Next up: ${nextTask.title}'
        : 'Done! Next up: ${nextTask.title}';
  }
  if (verdict == ProcessAction.done) return 'All done for today!';
  return stoppedAtLimit
      ? 'Stopped there. Nothing else planned.'
      : 'Sprint logged — nothing else planned.';
}

/// The task the session advances to after a Focus verdict on
/// [completedTodoId] — the first Plan member still owed attention.
///
/// A **Settled** task is skipped (#693 AC2): the user has already answered for
/// it this session, so re-presenting it as "next up" would hand back work they
/// are done with. `doneAt` stays as the cheap guard — a Settled done row is in
/// [settlements] anyway.
Todo? focusNextTask({
  required List<Todo> sessionTasks,
  required String completedTodoId,
  required Map<String, SessionSettlement> settlements,
}) =>
    sessionTasks
        .where((t) =>
            t.id != completedTodoId &&
            t.doneAt == null &&
            !settlements.containsKey(t.id))
        .firstOrNull;

/// The transition snackbar a Focus verdict leaves behind.
///
/// Top level so every surface that shows one shows the same one.
void showFocusAdvanceSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF2667B7),
    ),
  );
}
