import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/action_draft.dart';

void main() {
  group('ActionDraft', () {
    test('carries the phrase and both effort attributes', () {
      const draft = ActionDraft(
        text: 'Call the plumber',
        energyLevel: 'low',
        timeEstimateMinutes: 15,
      );
      expect(draft.text, 'Call the plumber');
      expect(draft.energyLevel, 'low');
      expect(draft.timeEstimateMinutes, 15);
    });

    test('effort attributes default to unset', () {
      const draft = ActionDraft(text: 'Call the plumber');
      expect(draft.energyLevel, isNull);
      expect(draft.timeEstimateMinutes, isNull);
    });

    test('equality is by value, so a sheet result can be asserted on', () {
      const a = ActionDraft(text: 'x', energyLevel: 'high', timeEstimateMinutes: 30);
      const b = ActionDraft(text: 'x', energyLevel: 'high', timeEstimateMinutes: 30);
      const c = ActionDraft(text: 'x', energyLevel: 'low', timeEstimateMinutes: 30);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith replaces only what it is given', () {
      const draft = ActionDraft(
        text: 'original',
        energyLevel: 'medium',
        timeEstimateMinutes: 45,
      );
      expect(
        draft.copyWith(text: 'renamed'),
        const ActionDraft(
          text: 'renamed',
          energyLevel: 'medium',
          timeEstimateMinutes: 45,
        ),
      );
    });

    test('copyWith clear flags null a value that a null argument would keep', () {
      const draft = ActionDraft(
        text: 'original',
        energyLevel: 'medium',
        timeEstimateMinutes: 45,
      );
      // A bare null argument means "keep" …
      expect(draft.copyWith(energyLevel: null).energyLevel, 'medium');
      expect(draft.copyWith(timeEstimateMinutes: null).timeEstimateMinutes, 45);
      // … the flag is the only way to clear.
      expect(draft.copyWith(clearEnergyLevel: true).energyLevel, isNull);
      expect(draft.copyWith(clearTimeEstimate: true).timeEstimateMinutes, isNull);
      // Clearing one leaves the other alone.
      expect(draft.copyWith(clearEnergyLevel: true).timeEstimateMinutes, 45);
    });
  });
}
