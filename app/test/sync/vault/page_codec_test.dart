import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/vault/page_codec.dart';

PageModel _page({String notes = 'Some notes.\n', List<BlockEntry>? block}) =>
    PageModel(
      frontmatter: {
        'id': 'a1b2',
        'title': 'Ship: the "thing"',
        'labels': ['x', 'y z'],
        'area': 'Work',
      },
      notes: notes,
      checklist: const [
        ChecklistLine(done: false, text: 'first'),
        ChecklistLine(done: true, text: 'second'),
      ],
      block: block ??
          [
            BlockEntry(
              collection: 'todos',
              entityId: 'a1b2',
              field: 'title',
              hlc: Hlc.forMember('0' * 32, 1700000000000, 2),
              digest: digestOf('Ship: the "thing"'),
            ),
            BlockEntry(
              collection: 'todos',
              entityId: 'a1b2',
              field: 'intent',
              hlc: Hlc.forMember('0' * 32, 1700000000001),
              digest: digestOf('go'),
              hasCarriedValue: true,
              carriedValue: 'go',
            ),
          ],
    );

void main() {
  test('render then parse gives back the page', () {
    final text = renderPage(_page());
    final parsed = parsePage(text);
    expect(parsed.frontmatter, _page().frontmatter);
    expect(parsed.notes, 'Some notes.\n');
    expect(parsed.checklist, _page().checklist);
    expect(parsed.block!.length, 2);
    expect(parsed.block!.firstWhere((e) => e.field == 'intent').carriedValue, 'go');
    expect(renderPage(parsed), text, reason: 'a page is a pure function of its model');
  });

  test('entries are written sorted, whatever order they came in', () {
    final entries = _page().block!;
    expect(
      renderPage(_page(block: entries)),
      renderPage(_page(block: entries.reversed.toList())),
    );
  });

  test('the block holds no double hyphen, so no value can close the comment', () {
    final text = renderPage(_page());
    final block = text.substring(text.lastIndexOf('<!-- jeeves-sync'));
    final body = block.replaceFirst('<!-- ', '').replaceFirst(RegExp(r'-->\n$'), '');
    expect(body.contains('--'), isFalse);
  });

  test('notes with a comment end or a task line survive', () {
    for (final notes in ['a --> b\n', '- [ ] looks like a task\n', '', 'no newline']) {
      final parsed = parsePage(renderPage(_page(notes: notes)));
      expect(parsed.notes, notes);
      expect(parsed.checklist.length, 2);
    }
  });

  test('a missing or mangled block is null, not an error', () {
    final text = renderPage(_page());
    final cut = text.substring(0, text.lastIndexOf('<!-- jeeves-sync'));
    expect(parsePage(cut).block, isNull);
    expect(parsePage(cut).checklist.length, 2);
    final mangled = text.replaceFirst('Leave this block alone.\n', 'Leave this block alone.\n!!');
    expect(parsePage(mangled).block, isNull);
  });

  test('a newer block version is left unread', () {
    final text = renderPage(_page()).replaceFirst('jeeves-sync 1', 'jeeves-sync 2');
    expect(parsePage(text).block, isNull);
  });

  test('a page without frontmatter or heading does not parse', () {
    expect(() => parsePage('hello'), throwsA(isA<PageParseException>()));
    expect(() => parsePage('---\nid: x\n---\nbody\n'), throwsA(isA<PageParseException>()));
  });

  test('a hand edit shows as a value that no longer matches its digest', () {
    expect(digestOf('Ship'), digestOf('Ship'));
    expect(digestOf('Ship'), isNot(digestOf('Ship it')));
  });

  test('windows line ends from another editor are read', () {
    final text = renderPage(_page()).replaceAll('\n', '\r\n');
    expect(parsePage(text).checklist.length, 2);
    expect(parsePage(text).block, isNotNull);
  });
}
