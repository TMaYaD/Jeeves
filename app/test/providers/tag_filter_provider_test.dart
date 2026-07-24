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

    test('clear resets to empty, and is a no-op when already empty', () {
      final container = makeContainer();
      addTearDown(container.dispose);
      final notifier = container.read(tagFilterProvider.notifier);
      notifier.toggle('tag-1');
      notifier.toggle('tag-2');
      notifier.clear();
      expect(container.read(tagFilterProvider), isEmpty);
      // Clearing again on an already-empty state stays empty.
      notifier.clear();
      expect(container.read(tagFilterProvider), isEmpty);
    });
  });
}
