import 'package:freezed_annotation/freezed_annotation.dart';

part 'reminder.freezed.dart';
part 'reminder.g.dart';

enum ReminderType { time, location }

@freezed
abstract class Reminder with _$Reminder {
  const factory Reminder({
    required String id,
    required String todoId,
    required ReminderType type,
    // For time-based reminders
    DateTime? scheduledAt,
    // For location-based reminders
    String? locationId,
    @Default(false) bool onArrival,
    @Default(false) bool onDeparture,
    required DateTime createdAt,
  }) = _Reminder;

  factory Reminder.fromJson(Map<String, dynamic> json) =>
      _$ReminderFromJson(json);
}
