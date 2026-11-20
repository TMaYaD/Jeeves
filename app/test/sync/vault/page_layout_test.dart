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
    expect(pageOwning(tag), isNull);
    expect(pageOwning(_change('time_logs', 'x', {'focus_session_id': 's1', 'task_id': 'o1'})),
        const VaultPageKey(VaultPageKind.session, 's1'));
    expect(pageOwning(_change('time_logs', 'x', {'task_id': 'o1'})), key);
  });
}
