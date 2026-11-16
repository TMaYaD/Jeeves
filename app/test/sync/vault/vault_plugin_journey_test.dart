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
}

Future<_VaultDevice> _open(String label, Directory root) async {
  final device = HostDevice.open(label);
  addTearDown(device.close);
  final host = await device.startHost();
  final directory = Directory('${root.path}/$label')..createSync(recursive: true);
  final plugin = VaultPlugin(folder: DirectoryVaultFolder(directory), sync: device.sync);
  await host.attach(plugin);
  return _VaultDevice(device, directory, plugin);
}

/// The syncer: every page of [from] replaces the same path in [to].
Future<void> _copyVault(_VaultDevice from, _VaultDevice to) async {
  for (final subfolder in ['Outcomes', 'Sessions', 'Inbox']) {
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

  test("a Capture's clarification typed by hand reaches the app", () async {
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
}

/// How many tag links the Outcome has.
Future<int> _linkCount(_VaultDevice device, String outcomeId) async {
  final row = await device.domain.customSelect(
    'SELECT COUNT(*) AS c FROM todo_tags WHERE todo_id = ?',
    variables: [Variable<String>(outcomeId)],
  ).getSingle();
  return row.read<int>('c');
}
