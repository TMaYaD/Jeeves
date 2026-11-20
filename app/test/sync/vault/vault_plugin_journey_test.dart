/// The vault plugin, end to end, with two devices and a folder syncer.
///
/// Real stores, real DAOs, real merge and real files in temporary folders. The
/// only stand-in is the file syncer: [_copyVault] copies each page from one
/// device's folder over the other's, the way a general syncer would.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/vault/page_codec.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
import 'package:jeeves/sync/vault/vault_folder_io.dart';
import 'package:jeeves/sync/vault/vault_plugin.dart';

import '../host/host_harness.dart';

const String _userId = 'vault-user';
const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';

class _VaultDevice {
  _VaultDevice(this.device, this.directory, this.plugin);

  final HostDevice device;
  final Directory directory;
  final VaultPlugin plugin;

  VaultFolder get folder => DirectoryVaultFolder(directory);

  Future<String> outcomePath() async {
    final files = await folder.listMarkdownFiles('Outcomes');
    expect(files, hasLength(1), reason: '${device.label} has one Outcome page');
    return files.single;
  }

  Future<String> outcomePage() async => (await folder.read(await outcomePath()))!;

  Future<Map<String, Object?>?> todoRow() async {
    final rows = await device.domain.customSelect(
      'SELECT title, notes, due_date FROM todos WHERE id = ?',
      variables: [Variable<String>(_outcomeId)],
    ).get();
    return rows.isEmpty ? null : rows.single.data;
  }

  Future<int> actionCount() async => (await device.domain.customSelect(
          'SELECT COUNT(*) AS c FROM actions WHERE outcome_id = ?',
          variables: [Variable<String>(_outcomeId)]).getSingle())
      .read<int>('c');

  /// The ids of the Outcome's Actions, in order.
  Future<List<String>> actionIds() async => (await device.domain.customSelect(
        'SELECT id FROM actions WHERE outcome_id = ? ORDER BY id',
        variables: [Variable<String>(_outcomeId)],
      ).get())
          .map((row) => row.read<String>('id'))
          .toList();
}

Future<_VaultDevice> _open(String label, Directory root, {String? folderName}) async {
  final device = HostDevice.open(label);
  addTearDown(device.close);
  final host = await device.startHost();
  final directory = Directory('${root.path}/${folderName ?? label}')
    ..createSync(recursive: true);
  final plugin = VaultPlugin(folder: DirectoryVaultFolder(directory), sync: device.sync);
  await host.attach(plugin);
  return _VaultDevice(device, directory, plugin);
}

/// The syncer: every page of [from] replaces the same path in [to].
Future<void> _copyVault(_VaultDevice from, _VaultDevice to) async {
  for (final subfolder in ['Outcomes', 'Sessions', 'Inbox', 'Jeeves']) {
    for (final path in await from.folder.listMarkdownFiles(subfolder)) {
      await to.folder.writeAtomically(path, (await from.folder.read(path))!);
    }
  }
}

Future<void> _settle(_VaultDevice a, _VaultDevice b) async {
  for (var round = 0; round < 2; round++) {
    await a.device.host!.deliverAll();
    await b.device.host!.deliverAll();
    await _copyVault(a, b);
    await b.plugin.rescan();
    await b.device.host!.deliverAll();
    await _copyVault(b, a);
    await a.plugin.rescan();
    await a.device.host!.deliverAll();
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('vault-journey'));
  tearDown(() => root.deleteSync(recursive: true));

  test('an Outcome written on one device appears as a page and reaches the other',
      () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Ship the vault', userId: _userId);
    await _settle(a, b);

    final page = await a.outcomePage();
    expect(page, contains('title: Ship the vault'));
    expect(page, contains('## Actions'));
    expect((await b.todoRow())?['title'], 'Ship the vault');
    expect(await b.outcomePage(), page,
        reason: 'two devices in one state write the same bytes');
  });

  test('different fields edited on two devices both survive', () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await _settle(a, b);

    a.device.wall.advance();
    await a.device.domain.todoDao.updateFields(_outcomeId, title: 'Plan v2');
    b.device.wall.advance();
    await b.device.domain.todoDao.updateFields(_outcomeId, notes: 'remember this');
    await _settle(a, b);

    for (final device in [a, b]) {
      final row = await device.todoRow();
      expect(row?['title'], 'Plan v2', reason: device.device.label);
      expect(row?['notes'], 'remember this', reason: device.device.label);
    }
    expect(await a.outcomePage(), await b.outcomePage());
  });

  test('a page edited by hand shows the edit in the app and on the other device',
      () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId);
    await _settle(a, b);

    final path = await a.outcomePath();
    final edited =
        (await a.outcomePage()).replaceFirst('title: Old title', 'title: New title');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();
    await _settle(a, b);

    expect((await a.todoRow())?['title'], 'New title');
    expect((await b.todoRow())?['title'], 'New title');
  });

  test('a ticked and an added checklist line become Actions', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Checklist', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final edited =
        (await a.outcomePage()).replaceFirst('## Actions\n', '## Actions\n- [ ] call Sam\n');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    expect(await a.actionCount(), 1);
    expect(await a.outcomePage(), contains('- [ ] call Sam'));
  });

  test('a deleted Outcome stays deleted when the other device\'s stale page arrives',
      () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Doomed', userId: _userId);
    await _settle(a, b);
    final stalePath = await b.outcomePath();
    final stalePage = await b.outcomePage();

    a.device.wall.advance(5000);
    await a.device.domain.todoDao.deleteOutcome(_outcomeId);
    await a.device.host!.deliverAll();
    expect(await a.todoRow(), isNull);
    expect(await a.outcomePage(), contains('deleted:'));

    // The syncer brings the stale page back to A.
    await a.folder.writeAtomically(stalePath, stalePage);
    await a.plugin.rescan();
    await a.device.host!.deliverAll();

    expect(await a.todoRow(), isNull, reason: 'the stale copy did not revive it');
    expect(await a.outcomePage(), contains('deleted:'));
  });

  test('two FocusSessions on the same day produce two sheets', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    final morning = await a.device.domain.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [_outcomeId],
      now: DateTime.utc(2026, 11, 17, 9),
    );
    await a.device.domain.focusSessionDao
        .closeSession(sessionId: morning, now: DateTime.utc(2026, 11, 17, 10));
    final afternoon = await a.device.domain.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [_outcomeId],
      now: DateTime.utc(2026, 11, 17, 14),
    );
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final sheets = await a.folder.listMarkdownFiles('Sessions');
    expect(sheets, hasLength(2), reason: 'one sheet per session');
    for (final sheet in sheets) {
      expect(sheet.split('/').last, startsWith('2026-11-17-'),
          reason: 'the sheet is named for the day the session started');
    }
    final ids = <String>{};
    for (final sheet in sheets) {
      ids.add(parsePage((await a.folder.read(sheet))!).frontmatter['id']! as String);
    }
    expect(ids, {morning, afternoon});
  });

  test('a session sheet edited by hand is not applied, and is written back',
      () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    final session = await a.device.domain.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [_outcomeId],
      now: DateTime.utc(2026, 11, 17, 9),
    );
    await a.device.domain.focusSessionDao
        .closeSession(sessionId: session, now: DateTime.utc(2026, 11, 17, 10));
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final sheets = await a.folder.listMarkdownFiles('Sessions');
    expect(sheets, hasLength(1));
    final path = sheets.single;
    final original = (await a.folder.read(path))!;

    // A sheet is read only: a hand edit to it is not applied, and the next
    // write puts the sheet back as it was.
    final edited = original.replaceFirst(
        RegExp(r'^started: .*$', multiLine: true), 'started: 2026-11-17T11:00:00.000Z');
    expect(edited, isNot(original),
        reason: 'the sheet carries the time the session started');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    expect(await a.folder.read(path), original,
        reason: 'the hand edit is not applied, and the sheet is written back');
  });

  test('a carried value changed inside the block is not taken, and is put back',
      () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    final session = await a.device.domain.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [_outcomeId],
      now: DateTime.utc(2026, 11, 17, 9),
    );
    await a.device.domain.focusSessionDao
        .closeSession(sessionId: session, now: DateTime.utc(2026, 11, 17, 10));
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = (await a.folder.listMarkdownFiles('Sessions')).single;
    final original = (await a.folder.read(path))!;
    final page = parsePage(original);
    final entries = page.block!;
    final target = entries.firstWhere(
        (e) => e.hasCarriedValue && e.carriedValue is String && !e.isTombstone);
    final before = (await a.device.host!.mergedEntity(
            target.collection, target.entityId))
        .fields[target.field]!
        .value;

    // The value is changed inside the block; its digest and clock are not.
    final tampered = renderPage(PageModel(
      frontmatter: page.frontmatter,
      notes: page.notes,
      checklist: page.checklist,
      block: [
        for (final e in entries)
          if (identical(e, target))
            BlockEntry(
              collection: e.collection,
              entityId: e.entityId,
              field: e.field,
              hlc: e.hlc,
              digest: e.digest,
              hasCarriedValue: true,
              carriedValue: '${e.carriedValue}-tampered',
            )
          else
            e,
      ],
    ));
    expect(tampered, isNot(original));
    await a.folder.writeAtomically(path, tampered);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final after = (await a.device.host!.mergedEntity(
            target.collection, target.entityId))
        .fields[target.field]!
        .value;
    expect(after, before,
        reason: 'a value that is not what the clock stamped is not taken');
    expect(await a.folder.read(path), original,
        reason: 'the next write puts the sheet back');
  });

  test('a Label typed into a page becomes a Tag and a link', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final edited =
        (await a.outcomePage()).replaceFirst('---\n', '---\nlabels: ["Home"]\n');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final tags = await a.device.domain.customSelect(
      'SELECT name FROM tags WHERE type = ?',
      variables: [Variable<String>('label')],
    ).get();
    expect(tags.map((row) => row.read<String>('name')).toList(), ['Home']);
    expect(await _linkCount(a, _outcomeId), 1);
    expect(await a.outcomePage(), contains('labels: ["Home"]'));
  });

  test('a Label taken off a page stops being a link', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    final tagId =
        await a.device.domain.tagDao.findOrCreateTag('Home', 'label', _userId);
    await a.device.domain.tagDao.assignTag(_outcomeId, tagId, _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    expect(await a.outcomePage(), contains('labels: ["Home"]'));
    final edited =
        (await a.outcomePage()).replaceFirst('labels: ["Home"]\n', '');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    expect(await _linkCount(a, _outcomeId), 0);
    expect(await a.outcomePage(), isNot(contains('labels:')));
  });

  test('the Area typed into a page becomes a link', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final edited =
        (await a.outcomePage()).replaceFirst('---\n', '---\narea: Studio\n');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final tags = await a.device.domain.customSelect(
      'SELECT name FROM tags WHERE type = ?',
      variables: [Variable<String>('area')],
    ).get();
    expect(tags.map((row) => row.read<String>('name')).toList(), ['Studio']);
    expect(await _linkCount(a, _outcomeId), 1);
    expect(await a.outcomePage(), contains('area: Studio'));
  });

  test('unticked lines reordered become the planned queue', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await a.device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'second',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final page = await a.outcomePage();
    expect(page, contains('- [ ] first\n- [ ] second'));
    await a.folder.writeAtomically(
      path,
      page.replaceFirst('- [ ] first\n- [ ] second', '- [ ] second\n- [ ] first'),
    );
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final rows = await a.device.domain.customSelect(
      'SELECT text FROM actions WHERE outcome_id = ? AND role = ? '
      'ORDER BY position',
      variables: [Variable<String>(_outcomeId), Variable<String>('planned')],
    ).get();
    expect(
        rows.map((row) => row.read<String>('text')).toList(), ['second', 'first']);
    expect(await a.outcomePage(), contains('- [ ] second\n- [ ] first'));
  });

  test('a line that is retitled and moved is one Action removed and one added',
      () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await a.device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'second',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final page = await a.outcomePage();
    expect(page, contains('- [ ] first\n- [ ] second'));
    final before = await a.device.domain.customSelect(
      'SELECT id, text FROM actions WHERE outcome_id = ? ORDER BY position',
      variables: [Variable<String>(_outcomeId)],
    ).get();
    final firstId = before
        .firstWhere((row) => row.read<String>('text') == 'first')
        .read<String>('id');

    // "first" is retitled and moved below "second". A line that is both is one
    // Action removed and one added: the text no longer names the Action, and
    // the line no longer sits where it was.
    await a.folder.writeAtomically(
      path,
      page.replaceFirst(
          '- [ ] first\n- [ ] second', '- [ ] second\n- [ ] FIRST'),
    );
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final after = await a.device.domain.customSelect(
      'SELECT id, text FROM actions WHERE outcome_id = ? ORDER BY position',
      variables: [Variable<String>(_outcomeId)],
    ).get();
    expect(after.map((row) => row.read<String>('text')).toList(),
        ['second', 'FIRST']);
    expect(after.map((row) => row.read<String>('id')), isNot(contains(firstId)),
        reason: 'the Action that was there is removed');
    expect(after.map((row) => row.read<String>('id')).toSet(), hasLength(2));
  });

  test("a Capture's clarification typed by hand reaches the app", () async {    final a = await _open('a', root);
    await a.device.domain.captureDao.insertCapture(
      CapturesCompanion(
        id: const Value('capture-1'),
        title: const Value('An idea'),
        notes: const Value('the body'),
        captureSource: const Value('manual'),
        createdAt: Value(DateTime.utc(2026, 11, 17, 8)),
        updatedAt: Value(DateTime.utc(2026, 11, 17, 8)),
        userId: const Value(_userId),
      ),
    );
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final sheets = await a.folder.listMarkdownFiles('Inbox');
    expect(sheets, hasLength(1));
    final path = sheets.single;
    final edited = (await a.folder.read(path))!.replaceFirst(
          '---\n',
          '---\nclarified_at: 2026-11-17T09:00:00.000Z\n',
        );
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final capture = await a.device.domain.captureDao.getCapture('capture-1');
    expect(capture?.clarifiedAt, DateTime.utc(2026, 11, 17, 9));
    expect(await a.folder.read(path),
        contains('clarified_at: 2026-11-17T09:00:00.000Z'));
  });

  test("a Capture's body edited by hand is not read back, and is written back",
      () async {
    final a = await _open('a', root);
    await a.device.domain.captureDao.insertCapture(
      CapturesCompanion(
        id: const Value('capture-1'),
        title: const Value('An idea'),
        notes: const Value('the body'),
        captureSource: const Value('manual'),
        createdAt: Value(DateTime.utc(2026, 11, 17, 8)),
        updatedAt: Value(DateTime.utc(2026, 11, 17, 8)),
        userId: const Value(_userId),
      ),
    );
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final pages = await a.folder.listMarkdownFiles('Inbox');
    expect(pages, hasLength(1));
    final path = pages.single;
    final original = (await a.folder.read(path))!;
    expect(original, contains('the body'));

    // The body of a Capture is written once and never read back: a hand edit
    // to it is not what the Capture says, and the page is written as it was.
    final edited = original.replaceFirst('the body', 'a body written by hand');
    expect(edited, isNot(original));
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    final capture = await a.device.domain.captureDao.getCapture('capture-1');
    expect(capture?.notes, 'the body',
        reason: 'the body is not read back');
    expect(await a.folder.read(path), original,
        reason: 'the page is written back as it was');
  });

  test('a page whose block was deleted still shows the hand edit', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final edited = (await a.outcomePage())
        .replaceFirst('title: Old title', 'title: New title')
        .replaceFirst(RegExp(r'<!-- jeeves-sync 1[\s\S]*'), '');
    await a.folder.writeAtomically(path, edited);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    expect((await a.todoRow())?['title'], 'New title');
  });

  test('a file with no id is left alone', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    const path = 'Outcomes/notes.md';
    const text = '---\ntitle: Notes\n---\n\n## Actions\n';
    await a.folder.writeAtomically(path, text);

    await a.plugin.rescan();
    expect(await a.folder.read(path), text);
  });

  test('a page that does not parse is not overwritten', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    const path = 'Outcomes/broken.md';
    const text = '---\nid: broken\n---\nno heading here\n';
    await a.folder.writeAtomically(path, text);

    await a.plugin.rescan();
    expect(await a.folder.read(path), text);
  });

  test('two files with the same id collapse to one', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    final page = await a.outcomePage();
    const copy = 'Outcomes/zzz-copy.md';
    await a.folder.writeAtomically(copy, page);

    await a.plugin.rescan();
    expect(await a.folder.read(copy), isNull,
        reason: 'the copy with the larger path is removed');
    expect(await a.folder.read(path), page);
  });

  test('a hand edit with a mangled block shows the edit', () async {
    final a = await _open('a', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    final path = await a.outcomePath();
    // The machine block is damaged: what is left of it cannot be read.
    final mangled = (await a.outcomePage())
        .replaceFirst('title: Old title', 'title: New title')
        .replaceFirst(
          RegExp(
              r'(Written by Jeeves\. Leave this block alone\.\n)[A-Za-z0-9+/=\n]*(-->)'),
          r'$1bm90IGJhc2U2NCE=$2',
        );
    expect(parsePage(mangled).block, isNull,
        reason: 'the block cannot be read');
    await a.folder.writeAtomically(path, mangled);
    a.device.wall.advance(5000);
    await a.plugin.rescan();

    expect((await a.todoRow())?['title'], 'New title');
    expect(await a.outcomePage(), contains('title: New title'));
  });

  test('a stale copy does not roll back a newer value', () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId);
    await _settle(a, b);

    // The other device keeps a copy of the page as it was.
    final stalePath = await b.outcomePath();
    final stalePage = await b.outcomePage();

    // This device renames the Outcome.
    a.device.wall.advance();
    await a.device.domain.todoDao.updateFields(_outcomeId, title: 'New title');
    await a.device.host!.deliverAll();
    await a.plugin.rescan();
    expect((await a.todoRow())?['title'], 'New title');

    // The syncer brings the older copy over the newer page.
    await a.folder.writeAtomically(stalePath, stalePage);
    await a.plugin.rescan();
    await a.device.host!.deliverAll();

    expect((await a.todoRow())?['title'], 'New title',
        reason: 'the older copy did not roll the title back');
    expect(await a.outcomePage(), contains('title: New title'));
  });

  test('a missing page file deletes nothing', () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Doomed', userId: _userId);
    await _settle(a, b);

    // The page is not in the folder any more: a syncer dropped it, or a person
    // deleted it. A file that is not there is not a deletion.
    await a.folder.remove(await a.outcomePath());
    await a.plugin.rescan();

    expect(await a.todoRow(), isNotNull,
        reason: 'a missing file is not a deletion');
    expect((await b.todoRow())?['title'], 'Doomed',
        reason: 'the other device still holds the Outcome');
  });

  test('a deletion stays deleted on both devices', () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Doomed', userId: _userId);
    await _settle(a, b);
    final stalePath = await b.outcomePath();
    final stalePage = await b.outcomePage();

    a.device.wall.advance(5000);
    await a.device.domain.todoDao.deleteOutcome(_outcomeId);
    await a.device.host!.deliverAll();
    await a.plugin.rescan();
    expect(await a.todoRow(), isNull);
    expect(await a.outcomePage(), contains('deleted:'));

    // The syncer brings the deletion to the other device.
    await _copyVault(a, b);
    await b.plugin.rescan();
    await b.device.host!.deliverAll();
    expect(await b.todoRow(), isNull,
        reason: 'the deletion reached the other device');
    expect(await b.outcomePage(), contains('deleted:'));

    // And the other device's older copy does not bring it back.
    await a.folder.writeAtomically(stalePath, stalePage);
    await a.plugin.rescan();
    await a.device.host!.deliverAll();
    expect(await a.todoRow(), isNull,
        reason: 'the older copy did not revive it');
  });

  test('a line added by hand becomes one Action on both devices', () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await _settle(a, b);

    // A person types a line into the page.
    final path = await a.outcomePath();
    await a.folder.writeAtomically(
      path,
      (await a.outcomePage())
          .replaceFirst('## Actions\n', '## Actions\n- [ ] call Sam\n'),
    );
    a.device.wall.advance(5000);
    await a.plugin.rescan();
    expect(await a.actionCount(), 1);

    // The syncer brings the page to the other device.
    await _copyVault(a, b);
    await b.plugin.rescan();
    await b.device.host!.deliverAll();
    expect(await b.actionCount(), 1,
        reason: 'the line is one Action, not one per device');
    expect(await b.actionIds(), await a.actionIds(),
        reason: 'both devices hold the same Action');

    await _settle(a, b);
    expect(await a.outcomePage(), await b.outcomePage(),
        reason: 'two devices in one state write the same bytes');
  });

  test('a page that arrives as a conflict copy is taken, and folded away',
      () async {
    final a = await _open('a', root);
    final b = await _open('b', root);
    await a.device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Old title', userId: _userId);
    await _settle(a, b);

    // This device renames the Outcome.
    a.device.wall.advance();
    await a.device.domain.todoDao.updateFields(_outcomeId, title: 'New title');
    await a.device.host!.deliverAll();
    await a.plugin.rescan();

    // The syncer cannot merge the two versions of the page, so it keeps both:
    // the copy arrives under a second name.
    await b.folder.writeAtomically('Outcomes/zz-conflict.md', await a.outcomePage());

    await b.plugin.rescan();
    await b.device.host!.deliverAll();

    expect((await b.todoRow())?['title'], 'New title');
    expect(await b.folder.listMarkdownFiles('Outcomes'), hasLength(1),
        reason: 'two copies of one page collapse to one');
    expect(await b.outcomePage(), contains('title: New title'));
  });

  group('pages the app keeps for itself', () {
    Future<String> readPage(_VaultDevice device, String path) async =>
        (await device.folder.read(path))!;

    test('a preference set on one device reaches the other', () async {
      final a = await _open('a', root);
      final b = await _open('b', root);
      await a.device.domain.userPreferencesDao
          .set(_userId, 'clarify_mode', '"nToM"');
      await _settle(a, b);

      expect(await b.device.domain.userPreferencesDao.get(_userId, 'clarify_mode'),
          '"nToM"');
      expect(await readPage(b, 'Jeeves/Preferences.md'),
          await readPage(a, 'Jeeves/Preferences.md'),
          reason: 'two devices in one state write the same bytes');
    });

    test('a Tag no page names reaches the other device', () async {
      final a = await _open('a', root);
      final b = await _open('b', root);
      await a.device.domain.tagDao.findOrCreateTag('Errands', 'area', _userId);
      await _settle(a, b);

      final rows = await b.device.domain
          .customSelect('SELECT name, type FROM tags')
          .get();
      expect(rows.map((row) => (row.read<String>('name'), row.read<String>('type'))),
          [('Errands', 'area')]);
      expect(await readPage(b, 'Jeeves/Tags.md'), await readPage(a, 'Jeeves/Tags.md'));
    });

    test('Sprints on two days produce two day sheets, and reach the other device',
        () async {
      final a = await _open('a', root);
      final b = await _open('b', root);
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
      final dao = a.device.domain.sprintDao;
      await dao.startSprint(
          taskId: _outcomeId,
          userId: _userId,
          plannedDurationMinutes: 25,
          now: DateTime.utc(2026, 11, 20, 9));
      await dao.endRunningSprint(userId: _userId, now: DateTime.utc(2026, 11, 20, 9, 25));
      await dao.startSprint(
          taskId: _outcomeId,
          userId: _userId,
          plannedDurationMinutes: 50,
          now: DateTime.utc(2026, 11, 21, 9));
      await dao.endRunningSprint(userId: _userId, now: DateTime.utc(2026, 11, 21, 9, 50));
      await _settle(a, b);

      expect(await a.folder.listMarkdownFiles('Jeeves'), containsAll([
        'Jeeves/Sprints/2026-11-20.md',
        'Jeeves/Sprints/2026-11-21.md',
      ]));
      final rows = await b.device.domain.customSelect(
          'SELECT started_at, ended_at, planned_duration_minutes, action_id '
          'FROM sprints ORDER BY started_at').get();
      expect(rows.map((row) => row.read<int>('planned_duration_minutes')), [25, 50]);
      expect(rows.map((row) => row.read<String>('started_at')),
          ['2026-11-20T09:00:00.000Z', '2026-11-21T09:00:00.000Z']);
      expect(rows.map((row) => row.read<String>('ended_at')),
          ['2026-11-20T09:25:00.000Z', '2026-11-21T09:50:00.000Z']);
      expect(rows.every((row) => row.read<String?>('action_id') != null), isTrue);
      for (final path in ['Jeeves/Sprints/2026-11-20.md', 'Jeeves/Sprints/2026-11-21.md']) {
        expect(await readPage(b, path), await readPage(a, path));
      }
    });

    test('a reinstall on the same folder brings back Sprints, preferences and Tags',
        () async {
      final a = await _open('a', root);
      await a.device.domain.todoDao
          .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
      await a.device.domain.userPreferencesDao
          .set(_userId, 'clarify_mode', '"nToM"');
      await a.device.domain.tagDao.findOrCreateTag('Errands', 'area', _userId);
      await a.device.domain.sprintDao.startSprint(
          taskId: _outcomeId,
          userId: _userId,
          plannedDurationMinutes: 25,
          now: DateTime.utc(2026, 11, 20, 9));
      await a.device.domain.sprintDao
          .endRunningSprint(userId: _userId, now: DateTime.utc(2026, 11, 20, 9, 25));
      await a.device.host!.deliverAll();
      await a.plugin.rescan();
      final before = {
        for (final path in await a.folder.listMarkdownFiles('Jeeves'))
          path: await readPage(a, path),
      };
      expect(before.keys, containsAll([
        'Jeeves/Preferences.md',
        'Jeeves/Tags.md',
        'Jeeves/Sprints/2026-11-20.md',
      ]));

      // A reinstall: new stores, the same folder.
      final reinstalled = await _open('a2', root, folderName: 'a');
      await reinstalled.device.host!.deliverAll();
      await reinstalled.plugin.rescan();
      await reinstalled.device.host!.deliverAll();

      final domain = reinstalled.device.domain;
      expect(await domain.userPreferencesDao.get(_userId, 'clarify_mode'), '"nToM"');
      expect(
          (await domain.customSelect('SELECT name, type FROM tags').get())
              .map((row) => row.read<String>('name')),
          contains('Errands'));
      final sprints = await domain.customSelect(
          'SELECT action_id, started_at, ended_at, planned_duration_minutes '
          'FROM sprints').get();
      expect(sprints, hasLength(1));
      expect(sprints.single.read<String>('started_at'), '2026-11-20T09:00:00.000Z');
      expect(sprints.single.read<String>('ended_at'), '2026-11-20T09:25:00.000Z');
      expect(sprints.single.read<int>('planned_duration_minutes'), 25);
      expect(sprints.single.read<String?>('action_id'), isNotNull);
      for (final entry in before.entries) {
        expect(await readPage(reinstalled, entry.key), entry.value,
            reason: '${entry.key} is unchanged by the reinstall');
      }
    });

    test('a page Jeeves keeps for itself is not read when edited by hand, '
        'and is written back', () async {
      final a = await _open('a', root);
      await a.device.domain.userPreferencesDao
          .set(_userId, 'clarify_mode', '"nToM"');
      await a.device.host!.deliverAll();
      await a.plugin.rescan();

      final original = await readPage(a, 'Jeeves/Preferences.md');
      final edited = original.replaceFirst('Edits here are not read.', 'I was here.');
      expect(edited, isNot(original));
      await a.folder.writeAtomically('Jeeves/Preferences.md', edited);
      a.device.wall.advance(5000);
      await a.plugin.rescan();

      expect(await readPage(a, 'Jeeves/Preferences.md'), original);
      expect(await a.device.domain.userPreferencesDao.get(_userId, 'clarify_mode'),
          '"nToM"');
    });
  });
}

/// How many tag links the Outcome has.
Future<int> _linkCount(_VaultDevice device, String outcomeId) async {
  final row = await device.device.domain.customSelect(
    'SELECT COUNT(*) AS c FROM todo_tags WHERE todo_id = ?',
    variables: [Variable<String>(outcomeId)],
  ).getSingle();
  return row.read<int>('c');
}
