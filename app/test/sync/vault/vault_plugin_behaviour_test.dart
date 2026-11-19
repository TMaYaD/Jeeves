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
import 'package:jeeves/sync/vault/page_codec.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
import 'package:jeeves/sync/vault/vault_folder_io.dart';
import 'package:jeeves/sync/vault/vault_health.dart';
import 'package:jeeves/sync/vault/vault_plugin.dart';

import '../host/host_harness.dart';

const String _userId = 'vault-user';
const String _outcomeId = '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f';
const String _otherOutcomeId = '8a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d';

/// A folder that refuses to write while [failing] is set.
///
/// The one way a delivery goes unacknowledged: the plugin takes the changes,
/// the page cannot be written, and the change stays owed.
class _RefusingFolder implements VaultFolder {
  _RefusingFolder(this.inner);

  final VaultFolder inner;
  bool failing = false;

  /// Whether the folder refuses to be listed at all.
  bool unlistable = false;

  /// The paths that cannot be read.
  final Set<String> unreadable = {};

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) {
    if (unlistable) throw StateError('the folder cannot be listed');
    return inner.listMarkdownFiles(subfolder);
  }

  @override
  Future<String?> read(String relativePath) {
    if (unreadable.contains(relativePath)) {
      throw StateError('the file cannot be read');
    }
    return inner.read(relativePath);
  }

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

  test('a hand edit the app cannot hold is not taken', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;

    // The intent is one of three words, and a title is at most as long as the
    // row allows. Another word and a longer title are hand edits the app
    // cannot hold: taking them would put a row the store refuses into the
    // sync store, and the Outcome would vanish from the app.
    final longTitle = 'x' * 501;
    await folder.writeAtomically(
      path,
      page.replaceFirst('title: Plan', 'title: $longTitle\nintent: Next'),
    );
    await plugin.rescan();

    expect(await _title(device), 'Plan',
        reason: 'the app took a title it cannot hold');
    expect(await _intent(device), 'next',
        reason: 'the app took an intent it cannot hold');
    final restored = (await folder.read(path))!;
    expect(restored, contains('title: Plan'), reason: 'the page was not put back');
    expect(restored, isNot(contains('Next')),
        reason: 'the page kept a word the app cannot hold');
  });

  test('two Outcomes whose names read alike have a page each', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    // Two names that read alike, so both want the same file name.
    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan!', userId: _userId);
    await device.domain.todoDao
        .insertOutcome(id: _otherOutcomeId, title: 'Plan?', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final paths = await folder.listMarkdownFiles('Outcomes');
    expect(paths, hasLength(2), reason: 'the two Outcomes share a page');

    final ids = <String>{};
    for (final path in paths) {
      final page = parsePage((await folder.read(path))!);
      ids.add(page.frontmatter['id']! as String);
    }
    expect(ids, {_outcomeId, _otherOutcomeId});

    expect(await _title(device, _outcomeId), 'Plan!');
    expect(await _title(device, _otherOutcomeId), 'Plan?');
  });

  test('a file that cannot be read does not stop the vault', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = _RefusingFolder(DirectoryVaultFolder(directory));
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'aaa', userId: _userId);
    await device.domain.todoDao
        .insertOutcome(id: _otherOutcomeId, title: 'bbb', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final paths = await folder.listMarkdownFiles('Outcomes');
    expect(paths, hasLength(2));

    // The first file cannot be read. The second is still read, so the hand
    // edit in it lands.
    final unreadable = paths.firstWhere((path) => path.contains('aaa'));
    final edited = paths.firstWhere((path) => path.contains('bbb'));
    folder.unreadable.add(unreadable);
    final page = (await folder.read(edited))!;
    await folder.writeAtomically(
      edited,
      page.replaceFirst('title: bbb', 'title: bbb edited'),
    );

    await plugin.rescan();

    expect(await _title(device, _otherOutcomeId), 'bbb edited');
  });

  test('a page that does not parse is left alone and reported in health',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    // A page a person has mangled: it does not parse, so the app cannot take
    // it and must not write over it.
    final broken = File('${directory.path}/Outcomes/mangled.md');
    broken.parent.createSync(recursive: true);
    broken.writeAsStringSync('---\nid: mangled\n---\nnot a page\n');

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    expect(broken.readAsStringSync(), contains('not a page'),
        reason: 'the page was written over');
    expect(health, isNotEmpty, reason: 'the vault said nothing about itself');
    expect(health.last.unreadablePageCount, 1,
        reason: 'the page it could not read was not reported');
  });

  test('a folder that cannot be listed is reported in health', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = _RefusingFolder(DirectoryVaultFolder(directory));
    folder.unlistable = true;
    final plugin = VaultPlugin(folder: folder, sync: device.sync);

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);

    // The folder cannot be reached. The vault still attaches: it reports the
    // folder, and the app keeps working.
    await host.attach(plugin);
    await pumpEventQueue();

    expect(health, isNotEmpty, reason: 'the vault said nothing about itself');
    expect(health.last.folderReachable, isFalse,
        reason: 'the unreachable folder was not reported');
  });
}

/// The Outcome's title, as the app holds it.
Future<String?> _title(HostDevice device, [String id = _outcomeId]) async {
  final rows = await device.domain.customSelect(
    'SELECT title FROM todos WHERE id = ?',
    variables: [Variable<String>(id)],
  ).get();
  return rows.isEmpty ? null : rows.single.read<String>('title');
}

/// The Outcome's intent, as the app holds it.
Future<String?> _intent(HostDevice device, [String id = _outcomeId]) async {
  final rows = await device.domain.customSelect(
    'SELECT intent FROM todos WHERE id = ?',
    variables: [Variable<String>(id)],
  ).get();
  return rows.isEmpty ? null : rows.single.read<String>('intent');
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
