/// The time a user chose in the time sheet (issue #1093).
///
/// The sheet writes nothing: it hands back what the user chose, and the
/// surface that opened it applies the choice — the Time context chip on an
/// existing Action, or the clarify card on the Action a Capture will create.
library;

import 'time_context.dart';

/// What the user chose in the time sheet.
sealed class TimeChoice {
  const TimeChoice();
}

/// The user cleared the time: the Action carries no window and no Time context.
final class ClearTimeChoice extends TimeChoice {
  const ClearTimeChoice();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ClearTimeChoice;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'ClearTimeChoice()';
}

/// A time to put on an Action: a named time window, or a one-time Time context.
sealed class ActionTimeDraft extends TimeChoice {
  const ActionTimeDraft();
}

/// One of the user's named time windows, by id.
final class TimeWindowDraft extends ActionTimeDraft {
  const TimeWindowDraft(this.windowId);

  final String windowId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeWindowDraft && other.windowId == windowId;

  @override
  int get hashCode => windowId.hashCode;

  @override
  String toString() => 'TimeWindowDraft($windowId)';
}

/// A one-time Time context: a From date, weekly days and hours, or both.
final class OneTimeDraft extends ActionTimeDraft {
  const OneTimeDraft(this.value);

  final TimeContext value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is OneTimeDraft && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'OneTimeDraft($value)';
}
