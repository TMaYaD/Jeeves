import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/search_query.dart';

void main() {
  group('SearchQuery.isEmpty', () {
    test('default instance is empty', () {
      expect(const SearchQuery().isEmpty, isTrue);
    });

    test('non-empty text makes it not empty', () {
      expect(const SearchQuery(text: 'hello').isEmpty, isFalse);
    });

    test('includeDone=true makes it not empty', () {
      expect(const SearchQuery(includeDone: true).isEmpty, isFalse);
    });

    test('non-empty energyLevels makes it not empty', () {
      expect(const SearchQuery(energyLevels: {'low'}).isEmpty, isFalse);
    });

    test('timeEstimateMaxMinutes set makes it not empty', () {
      expect(const SearchQuery(timeEstimateMaxMinutes: 30).isEmpty, isFalse);
    });
  });

  group('SearchQuery.copyWith', () {
    test('copies text', () {
      final q = const SearchQuery().copyWith(text: 'foo');
      expect(q.text, 'foo');
      expect(q.includeDone, isFalse);
    });

    test('clears timeEstimateMaxMinutes', () {
      final q = const SearchQuery(timeEstimateMaxMinutes: 60)
          .copyWith(clearTimeEstimate: true);
      expect(q.timeEstimateMaxMinutes, isNull);
    });

    test('clears dueDateBefore', () {
      final date = DateTime(2025);
      final q = SearchQuery(dueDateBefore: date)
          .copyWith(clearDueDateBefore: true);
      expect(q.dueDateBefore, isNull);
    });

    test('preserves unchanged fields', () {
      final original = SearchQuery(
        text: 'original',
        energyLevels: const {'low'},
        includeDone: true,
      );
      final updated = original.copyWith(text: 'updated');
      expect(updated.energyLevels, {'low'});
      expect(updated.includeDone, isTrue);
    });
  });
}
