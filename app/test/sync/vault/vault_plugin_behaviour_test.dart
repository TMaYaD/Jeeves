/// The vault plugin's own behaviour, on one device.
///
/// The journeys in `vault_plugin_journey_test.dart` are about what two devices
/// agree on. These are about what the plugin does with what it is handed: the
/// same batch twice, a write that never reached its base copy, a delivery the
/// folder refused.
///
/// Real stores, real files. The only stand-in is the folder that refuses to
/// write, which is how a delivery that is not acknowledged is made.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/host/change.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
import 'package:jeeves/sync/vault/vault_folder_io.dart';
import 'package:jeeves/sync/vault/vault_plugin.dart';

import '../host/host_harness.dart';

const String _userId = 'vault-user';
const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';

/// A folder that refuses to write while [failing] is set.
///
/// The one way a delivery goes unacknowledged: the plugin takes the changes,
/// the page cannot be written, and the change stays owed.
class _RefusingFolder implements VaultFolder {
  _RefusingFolder(this.inner);

  final VaultFolder inner;
  bool failing = false;

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) =>
      inner.listMarkdownFiles(subfolder);

  @override
  Future<String?> read(String relativePath) => inner.read(relativePath);

  @override
  Future<void> writeAtomically(String relativePath, String text) {
    if (failing) throw StateError('the folder cannot be written');
    return inner.writeAtomically(relativePath, text);
  }

  @override
  Future<void> remove(String relativePath) => inner.remove(relativePath);
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('vault-behaviour'));
  tearDown(() => root.deleteSync(recursive: true));

  test('the same batch delivered twice changes nothing', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;
    expect(page, contains('title: Plan'));

    // The same batch again: a device that crashed before it acknowledged takes
    // the same changes over.
    final batch = <SequencedChange>[
      SequencedChange(1, await host.mergedEntity('todos', _outcomeId)),
      SequencedChange(2, await host.mergedEntity('actions', await _actionId(device))),
    ];
    await plugin.deliver(batch);
    await plugin.deliver(batch);

    expect(await folder.read(path), page, reason: 'the page did not move');
    expect(await _actionCount(device), 1, reason: 'the Action was not made twice');
    expect((await _title(device)), 'Plan');
  });

  test('a crash between the page and its base copy changes nothing', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;

    // The crash: the page was written, its base copy was not.
    await device.sync.customStatement(
      'DELETE FROM vault_page_bases WHERE page_path = ?',
      [path],
    );

    // The next read takes the page again. It says what the device already
    // knows, so nothing changes — the same bytes, the same Action, no new clock.
    await plugin.rescan();

    expect(await folder.read(path), page, reason: 'the page did not move');
    expect(await _actionCount(device), 1, reason: 'the Action was not made twice');
    expect((await _title(device)), 'Plan');
  });

  test('a delivery the folder refused is taken again after a restart', () async {
    final directory = Directory('${root.path}/device')..createSync(recursive: true);
    final vault = Directory('${root.path}/vault')..createSync(recursive: true);

    final device = HostDevice.open('a', directory: directory);
    var deviceClosed = false;
    addTearDown(() async {
      if (!deviceClosed) await device.close();
    });
    final host = await device.startHost();
    final folder = _RefusingFolder(DirectoryVaultFolder(vault));
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    // The folder cannot be written, so the pages never reach it.
    folder.failing = true;
    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await host.deliverAll();

    expect(await host.cursorOf(VaultPlugin.pluginId), 0,
        reason: 'the refused delivery was not acknowledged');
    expect(await DirectoryVaultFolder(vault).listMarkdownFiles('Outcomes'),
        isEmpty);

    // The app restarts. The folder works again, and the batch the first
    // device never took is still owed.
    folder.failing = false;
    deviceClosed = true;
    await device.close();

    final restarted = HostDevice.open(
      'a',
      directory: directory,
      wall: WallClock(1700000000000 + 60000),
    );
    addTearDown(restarted.close);
    final restartedHost = await restarted.startHost();
    final restartedFolder = DirectoryVaultFolder(vault);
    final restartedPlugin =
        VaultPlugin(folder: restartedFolder, sync: restarted.sync);
    await restartedHost.attach(restartedPlugin);
    await restartedHost.deliverAll();

    expect(await restartedHost.cursorOf(VaultPlugin.pluginId), greaterThan(0),
        reason: 'the owed batch was taken');

    final paths = await restartedFolder.listMarkdownFiles('Outcomes');
    expect(paths, hasLength(1));
    final page = (await restartedFolder.read(paths.single))!;
    expect(page, contains('title: Plan'));
    expect(page, contains('- [ ] first'));

    expect(await _actionCount(restarted), 1,
        reason: 'the Action was made once, not once per delivery');
  });
}

/// The Outcome's title, as the app holds it.
Future<String?> _title(HostDevice device) async {
  final rows = await device.domain.customSelect(
    'SELECT title FROM todos WHERE id = ?',
    variables: [Variable<String>(_outcomeId)],
  ).get();
  return rows.isEmpty ? null : rows.single.read<String>('title');
}

/// How many Actions the Outcome has.
Future<int> _actionCount(HostDevice device) async {
  final row = await device.domain.customSelect(
    'SELECT COUNT(*) AS c FROM actions WHERE outcome_id = ?',
    variables: [Variable<String>(_outcomeId)],
  ).getSingle();
  return row.read<int>('c');
}

/// The id of the Outcome's one Action.
Future<String> _actionId(HostDevice device) async {
  final row = await device.domain.customSelect(
    'SELECT id FROM actions WHERE outcome_id = ?',
    variables: [Variable<String>(_outcomeId)],
  ).getSingle();
  return row.read<String>('id');
}
