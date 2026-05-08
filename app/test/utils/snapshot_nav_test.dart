import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/utils/snapshot_nav.dart';

void main() {
  group('SnapshotNav', () {
    test('unloaded: not loaded, not empty, not complete, no movement', () {
      const nav = SnapshotNav<int>();
      expect(nav.isLoaded, isFalse);
      expect(nav.isEmpty, isFalse);
      expect(nav.isComplete, isFalse);
      expect(nav.canGoBack, isFalse);
      expect(nav.canGoForward, isFalse);
      expect(nav.current, isNull);
      expect(nav.length, 0);
    });

    test('loaded empty: complete, terminal, no movement', () {
      final nav = const SnapshotNav<int>().withItems([]);
      expect(nav.isLoaded, isTrue);
      expect(nav.isEmpty, isTrue);
      expect(nav.isComplete, isTrue);
      expect(nav.canGoBack, isFalse);
      expect(nav.canGoForward, isFalse);
    });

    test('first item: forward yes, back no', () {
      final nav = const SnapshotNav<int>().withItems([10, 20, 30]);
      expect(nav.index, 0);
      expect(nav.current, 10);
      expect(nav.canGoBack, isFalse);
      expect(nav.canGoForward, isTrue);
      expect(nav.isComplete, isFalse);
    });

    test('middle item: forward yes, back yes', () {
      final nav = const SnapshotNav<int>().withItems([10, 20, 30]).next();
      expect(nav.index, 1);
      expect(nav.current, 20);
      expect(nav.canGoBack, isTrue);
      expect(nav.canGoForward, isTrue);
    });

    test('past last: complete, back yes, forward no', () {
      final nav =
          const SnapshotNav<int>().withItems([10, 20]).next().next();
      expect(nav.index, 2);
      expect(nav.current, isNull);
      expect(nav.isComplete, isTrue);
      expect(nav.canGoBack, isTrue);
      expect(nav.canGoForward, isFalse);
    });

    test('previous clamps at 0', () {
      final nav = const SnapshotNav<int>().withItems([10]);
      expect(nav.previous().index, 0);
      expect(nav.previous().canGoBack, isFalse);
    });

    test('equality compares items and index', () {
      final a = const SnapshotNav<int>().withItems([1, 2, 3]).next();
      final b = const SnapshotNav<int>().withItems([1, 2, 3]).next();
      final c = const SnapshotNav<int>().withItems([1, 2, 3]);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('copyWith(clearItems: true) resets to unloaded', () {
      final nav = const SnapshotNav<int>().withItems([1, 2]).next();
      final cleared = nav.copyWith(clearItems: true);
      expect(cleared.isLoaded, isFalse);
      expect(cleared.index, 0);
    });
  });
}
