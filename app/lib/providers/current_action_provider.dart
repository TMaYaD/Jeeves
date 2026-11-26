import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/current_action.dart';
import 'database_provider.dart';

/// The current Action of every Outcome, with the text it carries and the time
/// it governs, keyed by Outcome id (issue #1073).
///
/// One read: a surface that shows an Action's words and its time reads one
/// Action's, so a card never pairs one Action's text with another's time. A
/// time belongs to the Action and is not inherited by a successor, so the two
/// halves of a card have to come from the same row.
final currentActionsProvider =
    StreamProvider<Map<String, CurrentAction>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentActions();
});
