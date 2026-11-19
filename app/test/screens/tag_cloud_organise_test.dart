import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/tag_dao.dart' show TagWithCount;
import 'package:jeeves/database/gtd_database.dart' show Tag;
import 'package:jeeves/screens/common/tag_cloud.dart';

TagWithCount _twc(String id, String name, int count) => TagWithCount(
      tag: Tag(id: id, name: name, type: 'context', userId: 'u1'),
      count: count,
    );

List<String> _ids(TagCloudLayout l) =>
    l.visibleTags.map((t) => t.tag.id).toList();

List<String> _names(TagCloudLayout l) =>
    l.visibleTags.map((t) => t.tag.name).toList();

TagCloudLayout _organise(
  List<TagWithCount> tags, {
  Set<String> selected = const {},
  String query = '',
}) =>
    organiseTagCloud(
      tags: tags,
      selectedIds: selected,
      query: query,
    );

List<TagWithCount> _many(int n) =>
    [for (var i = 0; i < n; i++) _twc('t$i', 'tag${i.toString().padLeft(2, '0')}', n - i)];

void main() {
  group('organiseTagCloud', () {
    test('orders by name ignoring case, whatever the counts or selection',
        () {
      final layout = _organise([
        _twc('z', 'Zebra', 2),
        _twc('a', 'apple', 9),
        _twc('m', 'Mid', 5),
      ], selected: {'z'});
      expect(_names(layout), ['apple', 'Mid', 'Zebra']);
    });

    test('names equal but for case keep a fixed order by id', () {
      final layout = _organise([
        _twc('b', 'Home', 1),
        _twc('a', 'home', 1),
      ]);
      expect(_ids(layout), ['a', 'b']);
    });

    test('hides tags with no active tasks unless selected', () {
      final layout = _organise([
        _twc('a', 'busy', 3),
        _twc('b', 'idle', 0),
        _twc('c', 'idle-selected', 0),
      ], selected: {'c'});
      expect(_ids(layout), ['a', 'c']);
    });

    test('every eligible tag is visible', () {
      expect(_organise(_many(20)).visibleTags, hasLength(20));
      expect(_organise(_many(60)).visibleTags, hasLength(60));
    });

    test('offerFindField is false at twelve eligible tags, true at thirteen',
        () {
      expect(_organise(_many(12)).offerFindField, isFalse);
      expect(_organise(_many(13)).offerFindField, isTrue);
    });

    test('query matches case-insensitively and ignores a leading @', () {
      final tags = [..._many(20), _twc('x', 'Errands', 1)];
      final layout = _organise(tags, query: '@errAND');
      expect(_ids(layout), ['x']);
      expect(layout.offerFindField, isTrue);
    });

    test('query with no match yields an empty list', () {
      final layout = _organise(_many(20), query: 'nothing-like-this');
      expect(layout.visibleTags, isEmpty);
    });

    test('font size steps by count relative to the busiest visible tag', () {
      final layout = _organise([
        _twc('a', 'a', 9),
        _twc('b', 'b', 5),
        _twc('c', 'c', 2),
      ]);
      expect(layout.fontSizes, {'a': 15.0, 'b': 13.0, 'c': 12.0});
    });

    test('selected tag with zero count renders at the smallest size', () {
      final layout = _organise([
        _twc('a', 'a', 4),
        _twc('b', 'b', 0),
      ], selected: {'b'});
      expect(layout.fontSizes['b'], 12.0);
    });
  });

  group('organiseTagCloud includeUnusedTags', () {
    test('drops unused tags by default', () {
      final layout = _organise([_twc('a', 'used', 1), _twc('b', 'idle', 0)]);
      expect(_ids(layout), ['a']);
    });

    test('keeps unused tags, in name order, when asked', () {
      final layout = organiseTagCloud(
        tags: [_twc('b', 'idle', 0), _twc('a', 'used', 1)],
        selectedIds: const {},
        query: '',
        includeUnusedTags: true,
      );
      expect(_ids(layout), ['b', 'a']);
    });
  });

  group('cleanTagCloudQuery', () {
    test('drops a leading @ and the space after it, ignoring case', () {
      expect(cleanTagCloudQuery('@ Home'), 'home');
      expect(cleanTagCloudQuery('  @Home '), 'home');
    });
  });
}
