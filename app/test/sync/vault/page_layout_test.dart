import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/vault/page_codec.dart';
import 'package:jeeves/sync/vault/page_layout.dart';

Hlc _at(int ms) => Hlc.forMember('0' * 32, ms);

Change _change(String collection, String id, Map<String, Object?> values,
    {int ms = 1700000000000, Hlc? tombstone}) {
  return Change(
    collection: collection,
    entityId: id,
    fields: {for (final e in values.entries) e.key: ClockedValue(e.value, _at(ms))},
    tombstone: tombstone,
  );
}

void main() {
  final outcome = _change('todos', 'o1', {
    'title': 'Ship it',
    'notes': 'Some notes',
    'due_date': '2026-12-01T00:00:00.000Z',
    'user_id': 'u',
  });
  final planned = _change('actions', 'a2',
      {'outcome_id': 'o1', 'text': 'second', 'role': 'planned', 'position': 1});
  final first = _change('actions', 'a1',
      {'outcome_id': 'o1', 'text': 'first', 'role': 'planned', 'position': 0});
  final done = _change('actions', 'a3',
      {'outcome_id': 'o1', 'text': 'finished', 'role': 'done', 'position': null});
  final tag = _change('tags', 't1', {'name': 'Work', 'type': 'area'});
  final link = _change('todo_tags', 'l1', {'todo_id': 'o1', 'tag_id': 't1'});
  const key = VaultPageKey(VaultPageKind.outcome, 'o1');

  test('an Outcome page shows its fields and checklist, and is deterministic', () {
    final page = layOutPage(key, [done, planned, outcome, link, tag, first]);
    expect(page.frontmatter['title'], 'Ship it');
    expect(page.frontmatter['area'], 'Work');
    expect(page.frontmatter['due'], '2026-12-01T00:00:00.000Z');
    expect(page.notes, 'Some notes\n');
    expect([for (final l in page.checklist) '${l.done}:${l.text}'],
        ['false:first', 'false:second', 'true:finished']);
    final shuffled = layOutPage(key, [first, tag, link, outcome, planned, done]);
    expect(renderPage(shuffled), renderPage(page));
    expect(parsePage(renderPage(page)).checklist, page.checklist);
  });

  test('a field the page does not show travels in the block with its value', () {
    final page = layOutPage(key, [outcome]);
    final userId = page.block!.firstWhere((e) => e.field == 'user_id');
    expect(userId.hasCarriedValue, isTrue);
    expect(userId.carriedValue, 'u');
    final title = page.block!.firstWhere((e) => e.field == 'title');
    expect(title.hasCarriedValue, isFalse);
    expect(title.digest, digestOf('Ship it'));
  });

  test('a deleted Outcome keeps its content and gains a deleted date', () {
    final gone = _change('todos', 'o1', {'title': 'Ship it', 'user_id': 'u'},
        tombstone: _at(1700000100000));
    final page = layOutPage(key, [gone]);
    expect(page.frontmatter['title'], 'Ship it');
    expect(page.frontmatter['deleted'], '2023-11-14T22:15:00.000Z');
    expect(page.block!.any((e) => e.isTombstone), isTrue);
  });

  test('entities find their page', () {
    expect(pageOwning(planned), key);
    expect(pageOwning(link), key);
    expect(pageOwning(tag), const VaultPageKey(VaultPageKind.appOwned, 'tags'));
    expect(pageOwning(_change('time_logs', 'x', {'focus_session_id': 's1', 'task_id': 'o1'})),
        const VaultPageKey(VaultPageKind.session, 's1'));
    expect(pageOwning(_change('time_logs', 'x', {'task_id': 'o1'})), key);
  });

  group('pages the app keeps for itself', () {
    test('a Tag and a preference each go to one page of their own', () {
      expect(pageOwning(tag),
          const VaultPageKey(VaultPageKind.appOwned, 'tags'));
      expect(
          pageOwning(_change('user_preferences', 'p1', {'key': 'k', 'value': 'v'})),
          const VaultPageKey(VaultPageKind.appOwned, 'preferences'));
      expect(appOwnedPagePath('tags'), 'Jeeves/Tags.md');
      expect(appOwnedPagePath('preferences'), 'Jeeves/Preferences.md');
    });

    test('a Sprint goes to the page of the UTC day it started', () {
      VaultPageKey? at(Object? startedAt) => pageOwning(
          _change('sprints', 's1', {'started_at': startedAt, 'ended_at': null}));
      expect(at('2026-11-20T23:30:00.000Z'),
          const VaultPageKey(VaultPageKind.appOwned, 'sprints-2026-11-20'));
      expect(at('2026-11-21T00:10:00.000Z'),
          const VaultPageKey(VaultPageKind.appOwned, 'sprints-2026-11-21'));
      expect(at('2026-11-20T23:30:00.000-02:00'),
          const VaultPageKey(VaultPageKind.appOwned, 'sprints-2026-11-21'));
      expect(at('not a date'),
          const VaultPageKey(VaultPageKind.appOwned, 'sprints-undated'));
      expect(appOwnedPagePath('sprints-2026-11-20'), 'Jeeves/Sprints/2026-11-20.md');
      expect(appOwnedPagePath('sprints-undated'), 'Jeeves/Sprints/undated.md');
    });

    test('every value of such a page travels in the block', () {
      final page = layOutPage(
          const VaultPageKey(VaultPageKind.appOwned, 'tags'), [tag]);
      expect(page.frontmatter, {'id': 'tags'});
      expect(page.checklist, isEmpty);
      expect(page.block, isNotEmpty);
      expect(page.block!.every((entry) => entry.hasCarriedValue), isTrue);
    });
  });
}
