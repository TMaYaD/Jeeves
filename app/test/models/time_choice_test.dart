import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/models/time_choice.dart';
import 'package:jeeves/models/time_context.dart';

void main() {
  group('TimeChoice equality', () {
    test('a window draft is equal by its id', () {
      expect(const TimeWindowDraft('w1'), const TimeWindowDraft('w1'));
      expect(const TimeWindowDraft('w1').hashCode,
          const TimeWindowDraft('w1').hashCode);
      expect(const TimeWindowDraft('w1') == const TimeWindowDraft('w2'), isFalse);
    });

    test('a one-time draft is equal by its value', () {
      final a = TimeContext.create(fromDate: DateTime(2026, 12, 1))!;
      final b = TimeContext.create(fromDate: DateTime(2026, 12, 1))!;
      final c = TimeContext.create(fromDate: DateTime(2026, 12, 2))!;
      expect(OneTimeDraft(a), OneTimeDraft(b));
      expect(OneTimeDraft(a).hashCode, OneTimeDraft(b).hashCode);
      expect(OneTimeDraft(a) == OneTimeDraft(c), isFalse);
    });

    test('clear equals clear and nothing else', () {
      expect(const ClearTimeChoice(), const ClearTimeChoice());
      expect(const ClearTimeChoice() == const TimeWindowDraft('w1'), isFalse);
    });
  });

  group('ActionDraft.time', () {
    const base = ActionDraft(text: 'Buy hinges');

    test('copyWith keeps, replaces and clears the time', () {
      final withWindow = base.copyWith(time: const TimeWindowDraft('w1'));
      expect(withWindow.time, const TimeWindowDraft('w1'));
      expect(withWindow.copyWith(text: 'Buy screws').time,
          const TimeWindowDraft('w1'));
      expect(withWindow.copyWith(time: const TimeWindowDraft('w2')).time,
          const TimeWindowDraft('w2'));
      expect(withWindow.copyWith(clearTime: true).time, isNull);
    });

    test('equality includes the time', () {
      expect(base.copyWith(time: const TimeWindowDraft('w1')),
          base.copyWith(time: const TimeWindowDraft('w1')));
      expect(
          base.copyWith(time: const TimeWindowDraft('w1')) == base, isFalse);
    });
  });
}
