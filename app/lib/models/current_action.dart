/// current_action — the Outcome's current Action, with the time it carries.
///
/// One read of the current Action, so a surface that shows both the Action's
/// words and its time shows one Action's. A time belongs to the Action and is
/// not inherited by a successor, so a card that paired one Action's text with
/// another's time would describe an Action that never existed.
library;

import 'action_place_and_time_window.dart';
import 'time_context.dart';

/// The current Action of an Outcome.
///
/// [timeWindow] and [timeContext] are the Action's one time: a named window
/// governs when the Action carries one, so the two are never both set.
typedef CurrentAction = ({
  String actionId,
  String actionText,
  ActionTimeWindow? timeWindow,
  TimeContext? timeContext,
});
