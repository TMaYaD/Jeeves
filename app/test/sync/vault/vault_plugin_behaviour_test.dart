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
import 'package:jeeves/sync/hlc.dart';
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

  /// The folders that cannot be listed, while the others can.
  final Set<String> unlistableFolders = {};

  /// The paths that cannot be read.
  final Set<String> unreadable = {};

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) {
    if (unlistable) throw StateError('the folder cannot be listed');
    if (unlistableFolders.contains(subfolder)) {
      throw StateError('the folder cannot be listed');
    }
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

/// A folder where a path is replaced while the vault works, as a syncer that
/// writes while the vault reads would.
///
/// [arm] says what a path will hold, and the replacement happens on the
/// second read after that: the read the vault made, and the one it makes
/// before it writes.
class _SwappingFolder implements VaultFolder {
  _SwappingFolder(this.inner);

  final VaultFolder inner;

  /// The paths that are waiting for their replacement.
  final Set<String> armed = {};

  /// What a path holds after it is replaced.
  final Map<String, String> replacements = {};

  /// How many times each armed path has been read.
  final Map<String, int> reads = {};

  /// Arm [relativePath]: it will hold [text] on the second read from now.
  void arm(String relativePath, String text) {
    armed.add(relativePath);
    replacements[relativePath] = text;
    reads[relativePath] = 0;
  }

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) =>
      inner.listMarkdownFiles(subfolder);

  @override
  Future<String?> read(String relativePath) async {
    if (armed.contains(relativePath)) {
      final count = (reads[relativePath] ?? 0) + 1;
      reads[relativePath] = count;
      if (count == 2) {
        armed.remove(relativePath);
        await inner.writeAtomically(
            relativePath, replacements[relativePath]!);
      }
    }
    return inner.read(relativePath);
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) =>
      inner.writeAtomically(relativePath, text);

  @override
  Future<void> remove(String relativePath) => inner.remove(relativePath);
}

/// A folder whose page is replaced every time it is read, as a syncer that
/// keeps writing would.
class _RacingFolder implements VaultFolder {
  _RacingFolder(this.inner);

  final VaultFolder inner;

  /// The paths that keep changing.
  final Set<String> racing = {};

  /// The pages the plugin wrote.
  final List<String> pluginWrites = [];

  /// How many revisions have been written.
  int revisions = 0;

  @override
  Future<List<String>> listMarkdownFiles(String subfolder) =>
      inner.listMarkdownFiles(subfolder);

  @override
  Future<String?> read(String relativePath) async {
    if (racing.contains(relativePath)) {
      revisions++;
      final current = await inner.read(relativePath);
      if (current != null) {
        await inner.writeAtomically(
          relativePath,
          current.replaceFirst(
              RegExp(r'^title: .*$', multiLine: true), 'title: Plan $revisions'),
        );
      }
    }
    return inner.read(relativePath);
  }

  @override
  Future<void> writeAtomically(String relativePath, String text) {
    pluginWrites.add(relativePath);
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
    // The word the app cannot hold replaces the one the page holds: a second
    // `intent:` line would be read as the last one, and the test would pass on
    // a page the app never refused.
    final edited = page
        .replaceFirst('title: Plan', 'title: $longTitle')
        .replaceFirst('intent: next', 'intent: Next');
    expect(parsePage(edited).frontmatter['intent'], 'Next',
        reason: 'the fixture does not hold the word the app cannot hold');
    await folder.writeAtomically(path, edited);
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

  test('a title cleared by hand is not taken, and the page is put back',
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

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;
    expect(page, contains('title: Plan'));

    // The title line is gone. An Outcome has no title without one, and the
    // store refuses a row without it: the value is not carried, the app keeps
    // the title it has, and the next write puts the page back.
    await folder.writeAtomically(path, page.replaceFirst('title: Plan\n', ''));

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    expect(await _title(device), 'Plan',
        reason: 'the app took a title it cannot hold');
    expect((await folder.read(path))!, contains('title: Plan'),
        reason: 'the page was not put back');
    expect(health.last.untakenPageCount, 0,
        reason: 'the page was reported as one the host would not take');
  });

  test('a date that is not a date is not taken as a cleared date', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await device.domain.todoDao
        .updateFields(_outcomeId, dueDate: DateTime.utc(2026, 11, 20, 9));
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;
    expect(page, contains('due: 2026-11-20T09:00:00.000Z'));

    // The due date is replaced by something that is not a date. The key is
    // there, so the field is not cleared: the value is one the app cannot
    // hold, and the app keeps the date it has.
    await folder.writeAtomically(
      path,
      page.replaceFirst('due: 2026-11-20T09:00:00.000Z', 'due: ["not a date"]'),
    );
    await plugin.rescan();

    expect(await _dueDate(device), DateTime.utc(2026, 11, 20, 9),
        reason: 'the app took a date that is not a date');
    expect((await folder.read(path))!, contains('due: 2026-11-20T09:00:00.000Z'),
        reason: 'the page was not put back');
  });

  test('a page whose block a newer version wrote is kept, and reported',
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

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;

    // A second copy of the page, written by a version of Jeeves whose block
    // this one cannot read. The app has never seen it, so there is no base
    // copy to read it with either.
    const newer = 'Outcomes/aa-newer.md';
    final newerPage =
        page.replaceFirst('<!-- jeeves-sync 1', '<!-- jeeves-sync 2');
    expect(parsePage(newerPage).block, isNull,
        reason: 'the block of the newer page can be read');
    await folder.writeAtomically(newer, newerPage);

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    expect(await folder.read(newer), newerPage,
        reason: 'the page the app cannot read was written over');
    expect(await folder.read(path), isNotNull,
        reason: 'the page the app could read was removed');
    expect(health.last.unreadablePageCount, 1,
        reason: 'the page the app could not read was not reported');
  });

  test('a deleted page keeps its content on a device that never saw it',
      () async {
    final a = HostDevice.open('a');
    addTearDown(a.close);
    final aHost = await a.startHost();
    final aDirectory = Directory('${root.path}/vault-a')
      ..createSync(recursive: true);
    final aFolder = DirectoryVaultFolder(aDirectory);
    final aPlugin = VaultPlugin(folder: aFolder, sync: a.sync);
    await aHost.attach(aPlugin);

    await a.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.domain.todoDao.updateFields(_outcomeId, notes: 'the body');
    await aHost.deliverAll();
    await aPlugin.rescan();

    a.wall.advance(5000);
    await a.domain.todoDao.deleteOutcome(_outcomeId);
    await aHost.deliverAll();
    await aPlugin.rescan();

    final path = (await aFolder.listMarkdownFiles('Outcomes')).single;
    final deleted = (await aFolder.read(path))!;
    expect(deleted, contains('deleted:'));
    expect(deleted, contains('title: Plan'));
    expect(deleted, contains('the body'));

    // A device that has never seen the Outcome reads the page.
    final b = HostDevice.open('b');
    addTearDown(b.close);
    final bHost = await b.startHost();
    final bDirectory = Directory('${root.path}/vault-b')
      ..createSync(recursive: true);
    final bFolder = DirectoryVaultFolder(bDirectory);
    final bPlugin = VaultPlugin(folder: bFolder, sync: b.sync);
    await bHost.attach(bPlugin);
    await bFolder.writeAtomically(path, deleted);

    await bPlugin.rescan();

    // The page keeps what it says: its title and its notes travel with the
    // clocks the block carries, not with a hand edit's.
    final read = (await bFolder.read(path))!;
    expect(read, contains('title: Plan'), reason: 'the title was lost');
    expect(read, contains('the body'), reason: 'the notes were lost');
    expect(read, contains('deleted:'), reason: 'the deletion was lost');

    // And the Outcome stays deleted: the content it carried is older than the
    // deletion, so the app does not hold the Outcome.
    expect(await b.domain.todoDao.getTodo(_outcomeId), isNull,
        reason: 'the deleted Outcome came back');
  });

  test('a Label typed into a deleted page creates no Tag', () async {
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

    device.wall.advance(5000);
    await device.domain.todoDao.deleteOutcome(_outcomeId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final deleted = (await folder.read(path))!;
    expect(deleted, contains('deleted:'));

    // A person types a Label into the deleted page. The page is frozen, so
    // nothing is created from it.
    await folder.writeAtomically(
      path,
      deleted.replaceFirst('---\n', '---\nlabels: ["Home"]\n'),
    );
    await plugin.rescan();

    final tags = await device.domain.customSelect(
      'SELECT COUNT(*) AS c FROM tags WHERE name = ?',
      variables: [Variable<String>('Home')],
    ).getSingle();
    expect(tags.read<int>('c'), 0,
        reason: 'a Tag was created from a deleted page');
  });

  test('an Action whose position is not a number is left alone, and reported',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'aaa', userId: _userId);
    await device.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await device.domain.todoDao
        .insertOutcome(id: _otherOutcomeId, title: 'bbb', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final paths = await folder.listMarkdownFiles('Outcomes');
    expect(paths, hasLength(2));

    // The first page's block carries a position that is not a number.
    final first = paths.firstWhere((path) => path.contains('aaa'));
    final second = paths.firstWhere((path) => path.contains('bbb'));
    final parsed = parsePage((await folder.read(first))!);
    final tampered = renderPage(PageModel(
      frontmatter: parsed.frontmatter,
      notes: parsed.notes,
      checklist: parsed.checklist,
      block: [
        for (final entry in parsed.block!)
          if (entry.collection == 'actions' && entry.field == 'position')
            BlockEntry(
              collection: entry.collection,
              entityId: entry.entityId,
              field: entry.field,
              hlc: entry.hlc,
              digest: entry.digest,
              hasCarriedValue: true,
              carriedValue: '1',
            )
          else
            entry,
      ],
    ));
    await folder.writeAtomically(first, tampered);

    // The second page holds a hand edit, which lands.
    final edited = (await folder.read(second))!
        .replaceFirst('title: bbb', 'title: bbb edited');
    await folder.writeAtomically(second, edited);

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    expect(await folder.read(first), tampered,
        reason: 'the page the app cannot read was written over');
    expect(health.last.unreadablePageCount, 1,
        reason: 'the page the app could not read was not reported');
    expect(await _title(device, _otherOutcomeId), 'bbb edited',
        reason: 'the page after the one the app cannot read was not read');
  });

  test('a page the host refuses is kept, and read again', () async {
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

    // A page whose block carries a preference value with no key: the merge
    // core refuses that change, and the host says which change it refused.
    const refused = 'Outcomes/refused.md';
    await folder.writeAtomically(
      refused,
      renderPage(PageModel(
        frontmatter: {'id': _outcomeId, 'title': 'Refused'},
        notes: '',
        checklist: const [],
        block: [
          BlockEntry(
            collection: 'user_preferences',
            entityId: 'a-preference',
            field: 'value',
            hlc: Hlc.forMember(
                '00000000-0000-0000-0000-000000000000', 1700000000000),
            digest: digestOf('a value'),
            hasCarriedValue: true,
            carriedValue: 'a value',
          ),
        ],
      )),
    );

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    expect(await folder.read(refused), isNotNull,
        reason: 'the page the host refused was removed');
    expect(health.last.untakenPageCount, 1,
        reason: 'the page the host refused was not reported');
    expect(await _title(device), 'Plan',
        reason: 'the app took what the host refused');

    // The base copy was not saved: the page is read again on the next pass,
    // and it is still there to be read.
    final bases = await device.sync.customSelect(
      'SELECT COUNT(*) AS c FROM vault_page_bases WHERE page_path = ?',
      variables: [Variable<String>(refused)],
    ).getSingle();
    expect(bases.read<int>('c'), 0, reason: 'the base copy was saved');
  });

  test('a delivery the folder could not read is taken again', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = _RefusingFolder(DirectoryVaultFolder(directory));
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    expect(await folder.read(path), contains('title: Plan'));
    final cursor = await host.cursorOf(VaultPlugin.pluginId) ?? 0;

    // The page cannot be read when the Outcome is renamed, so it cannot be
    // written either: the change stays owed.
    folder.unreadable.add(path);
    await device.domain.todoDao.updateFields(_outcomeId, title: 'New plan');
    await host.deliverAll();

    expect(await host.cursorOf(VaultPlugin.pluginId), cursor,
        reason: 'the delivery was acknowledged although the page was not written');

    // The read recovers: the page is written, and the change is taken.
    folder.unreadable.clear();
    await host.deliverAll();

    expect(await folder.read(path), contains('title: New plan'));
    expect(await host.cursorOf(VaultPlugin.pluginId) ?? 0, greaterThan(cursor),
        reason: 'the change was not taken after the read recovered');
  });

  test('a write-back owed after an import is not forgotten', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = _RefusingFolder(DirectoryVaultFolder(directory));
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;

    // The intent is a word the app cannot hold, so the page the app holds and
    // the page in the folder differ: the folder has to be written back.
    await folder.writeAtomically(
      path,
      page.replaceFirst('intent: next', 'intent: Next'),
    );

    // The folder refuses the write.
    folder.failing = true;
    await plugin.rescan();

    expect(await folder.read(path), contains('intent: Next'),
        reason: 'the page was written over');

    // The folder works again. The page the app holds is written back, even
    // though the page in the folder now matches its base copy.
    folder.failing = false;
    await plugin.rescan();

    expect(await folder.read(path), contains('intent: next'),
        reason: 'the page was not put back');
  });

  test('a folder that cannot be listed is left alone', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final honest = DirectoryVaultFolder(directory);
    final folder = _RefusingFolder(honest);
    folder.unlistableFolders.add('Outcomes');
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    // The scan left the folder alone, so nothing is written into it: a page
    // written there is a page the scan never saw.
    expect(await honest.listMarkdownFiles('Outcomes'), isEmpty,
        reason: 'a page was written into a folder the scan left alone');

    // A later pass lists the folder: the page is written.
    folder.unlistableFolders.clear();
    await plugin.rescan();

    expect(await honest.listMarkdownFiles('Outcomes'), hasLength(1),
        reason: 'the page was not written once the folder could be listed');
  });

  test('a duplicate that changed while it was read is not removed', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final inner = DirectoryVaultFolder(directory);
    final folder = _SwappingFolder(inner);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;

    // A person edits the page, and a syncer brings a second copy of it.
    final edited = page.replaceFirst('title: Plan', 'title: Plan edited');
    await folder.writeAtomically(path, edited);
    const copy = 'Outcomes/zz-copy.md';
    await folder.writeAtomically(copy, edited);

    // The syncer replaces the copy while the vault is reading it.
    folder.arm(copy, edited.replaceFirst('title: Plan edited', 'title: Later'));

    await plugin.rescan();

    // Read through the inner folder: a read through the swapping folder would
    // itself trigger the replacement, and hide a copy that was removed.
    final copyPage = await inner.read(copy);
    expect(copyPage, isNotNull,
        reason: 'the copy the syncer replaced was removed');
    expect(copyPage, contains('title: Later'),
        reason: 'the copy does not hold the revision the syncer wrote');
  });

  test('a page that keeps changing is not written over', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final inner = DirectoryVaultFolder(directory);
    final folder = _RacingFolder(inner);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await inner.listMarkdownFiles('Outcomes')).single;
    expect(await inner.read(path), contains('title: Plan'));

    // The syncer keeps replacing the page: every read finds a new revision.
    folder.racing.add(path);
    folder.pluginWrites.clear();

    await plugin.rescan();

    expect(folder.pluginWrites, isEmpty,
        reason: 'the page was written over a revision that was not read');

    // The syncer stops: the page is written, with what the app holds.
    folder.racing.clear();
    await plugin.rescan();

    expect(folder.pluginWrites, isNotEmpty,
        reason: 'the page was never written');
  });

  test('a revision that arrived after the read is not replaced', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final inner = DirectoryVaultFolder(directory);
    final folder = _SwappingFolder(inner);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await host.deliverAll();
    await plugin.rescan();

    final path = (await inner.listMarkdownFiles('Outcomes')).single;
    final page = (await inner.read(path))!;

    // The Outcome is renamed, so the page has to be written. The syncer
    // brings a revision of its own while the vault is reading.
    await device.domain.todoDao
        .updateFields(_outcomeId, title: 'New plan');
    folder.arm(
        path, page.replaceFirst('title: Plan', 'title: From the syncer'));
    await host.deliverAll();

    final after = (await inner.read(path))!;
    expect(after, contains('title: From the syncer'),
        reason: 'the revision the syncer wrote was replaced');
  });

  test('two Outcomes whose names end in an id have a page each', () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = DirectoryVaultFolder(directory);
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    // Both Outcomes are named after the second one's id, so both want the
    // same page — and the name one of them wants already ends in an id.
    await device.domain.todoDao.insertOutcome(
      id: _outcomeId,
      title: 'Plan-$_otherOutcomeId',
      userId: _userId,
    );
    await device.domain.todoDao.insertOutcome(
      id: _otherOutcomeId,
      title: 'Plan-$_otherOutcomeId',
      userId: _userId,
    );
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

  test('a copy the host will not take is kept, and taken after a retry',
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
    await device.domain.todoDao.updateFields(_outcomeId, notes: 'the body');
    await host.deliverAll();
    await plugin.rescan();

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final page = (await folder.read(path))!;
    expect(page, contains('title: Plan'));

    // A person edited the page, and a syncer brought a second copy of it: two
    // versions of one page, each holding an edit the other does not.
    final copy = 'Outcomes/zz-plan-copy.md';
    await folder.writeAtomically(
        path, page.replaceFirst('title: Plan', 'title: Plan edited'));
    await folder.writeAtomically(
        copy, page.replaceFirst('the body', 'a body written by hand'));

    // The store that holds the merge state cannot be written, so the host
    // cannot take what the pages say.
    await device.sync.customStatement(
      'CREATE TRIGGER fail_merge BEFORE INSERT ON reduced_fields '
      "BEGIN SELECT RAISE(ABORT, 'the store cannot hold it'); END",
    );

    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await plugin.rescan();
    await pumpEventQueue();

    // Each edit is in one file and nowhere else. Neither file is removed and
    // neither is written over, and the app has taken nothing.
    expect(await folder.read(path), contains('title: Plan edited'),
        reason: 'the page was written over');
    expect(await folder.read(copy), contains('a body written by hand'),
        reason: 'the copy was removed');
    expect(await _title(device), 'Plan',
        reason: 'the app took what the host refused');
    expect(await _notes(device), 'the body');
    expect(health.last.untakenPageCount, 1,
        reason: 'the page the host would not take was not reported');

    // The store works again. The next read takes both edits and folds the
    // copy in.
    await device.sync.customStatement('DROP TRIGGER fail_merge');
    await plugin.rescan();

    expect(await _title(device), 'Plan edited', reason: 'the edit was not taken');
    expect(await _notes(device), 'a body written by hand');
    expect(await folder.listMarkdownFiles('Outcomes'), hasLength(1),
        reason: 'the copy was not folded in');
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

  test('a page that cannot be read is owed its write, and gets it once repaired',
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

    final path = (await folder.listMarkdownFiles('Outcomes')).single;
    final original = (await folder.read(path))!;

    // The page is mangled, and then the app changes the Outcome: the write
    // cannot be made, and it is not forgotten.
    await folder.writeAtomically(path, 'not a page\n');
    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await device.domain.todoDao.updateFields(_outcomeId, title: 'Plan changed');
    await host.deliverAll();
    await pumpEventQueue();
    expect(await folder.read(path), 'not a page\n',
        reason: 'the mangled page was written over');
    expect(health.last.owedWriteBackCount, 1,
        reason: 'the write the page is owed was forgotten');

    // The person puts the page back as it was; the next pass writes the title.
    await folder.writeAtomically(path, original);
    await plugin.rescan();
    expect(await folder.read(path), contains('Plan changed'));
  });

  test('a page that cannot be written is owed, and counted in health',
      () async {
    final device = HostDevice.open('a');
    addTearDown(device.close);
    final host = await device.startHost();
    final directory = Directory('${root.path}/vault')..createSync(recursive: true);
    final folder = _RefusingFolder(DirectoryVaultFolder(directory));
    folder.failing = true;
    final plugin = VaultPlugin(folder: folder, sync: device.sync);
    await host.attach(plugin);

    await device.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);

    // The folder refuses to write. The delivery fails, so the change is taken
    // again, and the page is owed a write.
    final health = <VaultHealth>[];
    plugin.health.listen(health.add);
    await host.deliverAll();
    await plugin.rescan();
    await pumpEventQueue();

    expect(await folder.listMarkdownFiles('Outcomes'), isEmpty,
        reason: 'the page was written to a folder that refuses it');
    expect(health, isNotEmpty, reason: 'the vault said nothing about itself');
    expect(health.last.owedWriteBackCount, 1,
        reason: 'the page that owes a write was not reported');

    // The folder works again. The next pass writes the page that was owed.
    folder.failing = false;
    await plugin.rescan();
    await pumpEventQueue();

    expect(await folder.listMarkdownFiles('Outcomes'), hasLength(1),
        reason: 'the owed page was not written');
    expect(health.last.owedWriteBackCount, 0,
        reason: 'the page was still owed after it was written');
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

  test('a hand edit is stamped after the clocks the page carries', () async {
    final a = HostDevice.open('a');
    addTearDown(a.close);
    final aHost = await a.startHost();
    final aDirectory = Directory('${root.path}/vault-a')
      ..createSync(recursive: true);
    final aFolder = DirectoryVaultFolder(aDirectory);
    final aPlugin = VaultPlugin(folder: aFolder, sync: a.sync);
    await aHost.attach(aPlugin);

    await a.domain.todoDao
        .insertOutcome(id: _outcomeId, title: 'Plan', userId: _userId);
    await a.domain.actionDao.addPlannedAction(
      _outcomeId,
      'first',
      now: DateTime.utc(2026, 11, 17, 8),
    );
    await aHost.deliverAll();
    await aPlugin.rescan();

    final path = (await aFolder.listMarkdownFiles('Outcomes')).single;
    final page = (await aFolder.read(path))!;
    expect(page, contains('- [ ] first'));

    // A person takes the line off the page.
    final edited = page.replaceFirst('- [ ] first\n', '');

    // A device whose own clock is behind reads the page.
    final b = HostDevice.open('b', wall: WallClock(1600000000000));
    addTearDown(b.close);
    final bHost = await b.startHost();
    final bDirectory = Directory('${root.path}/vault-b')
      ..createSync(recursive: true);
    final bFolder = DirectoryVaultFolder(bDirectory);
    final bPlugin = VaultPlugin(folder: bFolder, sync: b.sync);
    await bHost.attach(bPlugin);

    // The syncer brings the page.
    await bFolder.writeAtomically(path, edited);

    await bPlugin.rescan();

    // The Action is gone. The tombstone the hand edit was stamped with is
    // later than the clock the page carried for the Action, so the Action's
    // own fields are not left live.
    final actions = await b.domain.customSelect(
      'SELECT COUNT(*) AS c FROM actions WHERE outcome_id = ?',
      variables: [Variable<String>(_outcomeId)],
    ).getSingle();
    expect(actions.read<int>('c'), 0, reason: 'the Action was not deleted');
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

/// The Outcome's notes, as the app holds them.
Future<String?> _notes(HostDevice device, [String id = _outcomeId]) async {
  final rows = await device.domain.customSelect(
    'SELECT notes FROM todos WHERE id = ?',
    variables: [Variable<String>(id)],
  ).get();
  return rows.isEmpty ? null : rows.single.read<String>('notes');
}

/// The Outcome's due date, as the app holds it.
Future<DateTime?> _dueDate(HostDevice device, [String id = _outcomeId]) async =>
    (await device.domain.todoDao.getTodo(id))?.dueDate;

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
