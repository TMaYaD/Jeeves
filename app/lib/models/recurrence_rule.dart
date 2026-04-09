import 'package:freezed_annotation/freezed_annotation.dart';

part 'recurrence_rule.freezed.dart';
part 'recurrence_rule.g.dart';

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

@freezed
class RecurrenceRule with _$RecurrenceRule {
  const factory RecurrenceRule({
    required String id,
    required String todoId,
    required RecurrenceFrequency frequency,
    @Default(1) int interval,
    // Days of week (0=Sun..6=Sat) for weekly recurrence
    @Default([]) List<int> byDayOfWeek,
    // Day of month for monthly recurrence
    int? byDayOfMonth,
    DateTime? until,
    int? count,
  }) = _RecurrenceRule;

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) =>
      _$RecurrenceRuleFromJson(json);
}
