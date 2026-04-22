import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/tag_filter_provider.dart';

void main() {
  group('TagFilterNotifier', () {
    ProviderContainer makeContainer() => ProviderContainer();

    test('initial state is empty', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      expect(container.read(tagFilterProvider), isEmpty);
    });

    test('toggle adds a tag ID', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      expect(container.read(tagFilterProvider), {'tag-1'});
    });

    test('toggle removes an already-selected tag ID', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      expect(container.read(tagFilterProvider), isEmpty);
    });

    test('toggle with multiple tags accumulates correctly', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      container.read(tagFilterProvider.notifier).toggle('tag-2');
      expect(container.read(tagFilterProvider), {'tag-1', 'tag-2'});
    });

    test('toggle removing one tag preserves others', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      container.read(tagFilterProvider.notifier).toggle('tag-2');
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      expect(container.read(tagFilterProvider), {'tag-2'});
    });

    test('clear resets to empty', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).toggle('tag-1');
      container.read(tagFilterProvider.notifier).toggle('tag-2');
      container.read(tagFilterProvider.notifier).clear();
      expect(container.read(tagFilterProvider), isEmpty);
    });

    test('clear on already-empty state is a no-op', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      container.read(tagFilterProvider.notifier).clear();
      expect(container.read(tagFilterProvider), isEmpty);
    });
  });
}
