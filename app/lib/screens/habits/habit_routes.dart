/// How the app opens a Habit's detail: a pushed route on a phone, the right
/// pane of the list at 840 px or wider.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// The width from which the list and the detail sit side by side.
const double habitsWideBreakpointWidth = 840;

/// Route of the Habit list.
const habitsListPath = '/habits';

/// Route of a new Habit's draft.
const habitNewPath = '/habits/new';

/// Route of one Habit's detail on a phone.
String habitDetailPath(String habitId) => '/habits/$habitId';

/// Route of one Habit's Focus Mode screen. It sits outside the shell, like the
/// Outcome Focus screen.
String habitFocusPath(String habitId) => '/habits/$habitId/focus';

/// Opens Focus Mode on [habitId]. Every entry (the detail, "Right ho" and the
/// reminder) calls this one function.
void openHabitFocus(BuildContext context, String habitId) =>
    context.push(habitFocusPath(habitId));

/// Opens the detail of [habitId] (or a new draft when null).
///
/// [justCreated] shows the "new" banner once. [replace] swaps the current
/// route instead of pushing, as the draft does when it first saves.
void openHabitDetail(
  BuildContext context,
  String? habitId, {
  bool justCreated = false,
  bool replace = false,
}) {
  final wide = MediaQuery.sizeOf(context).width >= habitsWideBreakpointWidth;
  final query = justCreated ? '?new=1' : '';
  if (wide) {
    context.go(
      '$habitsListPath?habit=${habitId ?? 'new'}'
      '${justCreated ? '&new=1' : ''}',
    );
    return;
  }
  final path =
      '${habitId == null ? habitNewPath : habitDetailPath(habitId)}$query';
  if (replace) {
    context.pushReplacement(path);
  } else {
    context.push(path);
  }
}
