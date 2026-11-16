/// The vault plugin, end to end, with two devices and a folder syncer.
///
/// Real stores, real DAOs, real merge and real files in temporary folders. The
/// only stand-in is the file syncer: [_copyVault] copies each page from one
/// device's folder over the other's, the way a general syncer would.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
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
}
