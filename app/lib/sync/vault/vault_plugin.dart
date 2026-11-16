/// The vault plugin: sync through a folder of Markdown pages.
///
/// A **carrier only**. It turns a page into [Change]s and hands them to the host,
/// and writes the host's merged state back as a page. It never compares two
/// clocks and never chooses between two values — every value read from a page
/// goes to [SyncHost.applyRemote] and the host's merge decides. Its only
/// authorship is a clock for a hand edit, from [SyncHost.mintClock].
///
/// Page text is `page_codec.dart`; which entity sits on which page is
/// `page_layout.dart`; the folder is a [VaultFolder].
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../collection_codecs.dart';
import '../hlc.dart';
import '../host/change.dart';
import '../host/sync_host.dart';
import '../ids.dart';
import '../sync_database.dart';
import 'page_codec.dart';
import 'page_layout.dart';
import 'vault_folder.dart';

class VaultPlugin implements SyncPlugin {
  VaultPlugin({required VaultFolder folder, required SyncDatabase sync})
      : _folder = folder,
        _sync = sync;

  static const String pluginId = 'vault';

  final VaultFolder _folder;
  final SyncDatabase _sync;
  late SyncHost _host;
  final StreamController<PluginHealth> _health = StreamController.broadcast();

  /// Entities on each page: `collection/entityId`. Built from the host's
  /// snapshot at start and grown by every delivery and every page read.
  final Map<VaultPageKey, Set<String>> _members = {};
  final Map<VaultPageKey, String> _paths = {};
  Future<void> _tail = Future<void>.value();

  @override
  String get id => pluginId;

  @override
  Stream<PluginHealth> get health => _health.stream;

  @override
  Future<void> start(SyncHost host) async {
    _host = host;
    await _exclusive(_fullPass);
  }

  @override
  Future<void> stop() async {
    await _tail;
  }

  /// Read the folder again: what another device's syncer brought, and what a
  /// person typed. Called when the app comes to the foreground and on a timer.
  Future<void> rescan() => _exclusive(() async {
        final keys = await _scanAll();
        for (final key in keys) {
          await _writePage(key);
        }
        _reportSynced();
      });

  /// Forget this device's base copies. Called when the vault is turned off.
  Future<void> clearBases() =>
      _sync.customStatement('DELETE FROM vault_page_bases');

  @override
  Future<int> deliver(List<SequencedChange> changes) =>
      _exclusive(() async {
        final dirty = <VaultPageKey>{};
        for (final sequenced in changes) {
          final change = sequenced.change;
          final merged =
              await _host.mergedEntity(change.collection, change.entityId);
          final key = _register(merged);
          if (key != null) dirty.add(key);
          if (change.collection == tagsCollection) {
            final ref = '${change.collection}/${change.entityId}';
            for (final entry in _members.entries) {
              if (entry.value.contains(ref)) dirty.add(entry.key);
            }
          }
        }
        for (final key in dirty) {
          await _writePage(key);
        }
        _reportSynced();
        return changes.isEmpty ? 0 : changes.last.sequence;
      });

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  void _reportSynced() =>
      _health.add(PluginHealth(lastSyncedAt: DateTime.now().toUtc()));

  // --- full pass -------------------------------------------------------------

  /// Every start: read what is in the folder, then write every page that is
  /// missing or differs from merged state. This is the first upload too.
  Future<void> _fullPass() async {
    final fromFolder = await _scanAll();
    final keys = <VaultPageKey>{...fromFolder};
    await for (final change in _host.snapshot()) {
      final key = _register(change);
      if (key != null) keys.add(key);
    }
    for (final key in keys) {
      await _writePage(key);
    }
    _reportSynced();
  }

  VaultPageKey? _register(Change change) {
    final key = pageOwning(change);
    if (key == null) return null;
    final members = _members.putIfAbsent(key, () => <String>{});
    members.add('${change.collection}/${change.entityId}');
    final tagId = linkedTagId(change);
    if (tagId != null) members.add('$tagsCollection/$tagId');
    return key;
  }

  // --- reading the folder ----------------------------------------------------

  /// Read every page, apply what is news, and return the pages touched.
  Future<Set<VaultPageKey>> _scanAll() async {
    final touched = <VaultPageKey>{};
    for (final kind in VaultPageKind.values) {
      final byId = <String, List<({String path, String text, PageModel page})>>{};
      for (final path in await _folder.listMarkdownFiles(kind.folder)) {
        final text = await _folder.read(path);
        if (text == null) continue;
        final PageModel page;
        try {
          page = parsePage(text);
        } on PageParseException catch (error) {
          debugPrint('vault: $path left alone: ${error.message}');
          continue;
        }
        final pageId = page.frontmatter['id'];
        if (pageId is! String) continue; // not a Jeeves page
        (byId[pageId] ??= []).add((path: path, text: text, page: page));
      }
      for (final entry in byId.entries) {
        final copies = entry.value..sort((a, b) => a.path.compareTo(b.path));
        final key = VaultPageKey(kind, entry.key);
        for (final copy in copies) {
          if (copy.text != await _baseOf(copy.path)) {
            await _ingest(key, copy.path, copy.text, copy.page);
            touched.add(key);
          }
        }
        _paths[key] = copies.first.path;
        _members.putIfAbsent(key, () => <String>{});
        // Concurrent versions of one page were all read; keep one.
        for (final extra in copies.skip(1)) {
          await _folder.remove(extra.path);
          await _dropBase(extra.path);
          touched.add(key);
        }
      }
    }
    return touched;
  }

  Future<void> _ingest(
      VaultPageKey key, String path, String text, PageModel page) async {
    final base = await _baseOf(path);
    PageModel? baseModel;
    if (base != null) {
      try {
        baseModel = parsePage(base);
      } on PageParseException {
        baseModel = null;
      }
    }
    final changes = _changesFromPage(key, page, baseModel);
    if (changes.isNotEmpty) {
      await _host.applyRemote(id, changes);
      final members = _members.putIfAbsent(key, () => <String>{});
      for (final change in changes) {
        members.add('${change.collection}/${change.entityId}');
        final tagId = linkedTagId(change);
        if (tagId != null) members.add('$tagsCollection/$tagId');
      }
    }
    await _saveBase(path, text);
  }

  /// What a page says, as changes. Block entries pass through with their own
  /// clocks; a value that no longer matches its digest, or a checklist line that
  /// no longer matches an Action, is a hand edit and gets a fresh clock.
  List<Change> _changesFromPage(
      VaultPageKey key, PageModel page, PageModel? base) {
    final fields = <String, Map<String, ClockedValue>>{};
    final tombstones = <String, Hlc>{};
    final refs = <String, ({String collection, String entityId})>{};

    void touch(String collection, String entityId) =>
        refs['$collection/$entityId'] = (collection: collection, entityId: entityId);

    void addField(String collection, String entityId, String field,
        Object? value, Hlc hlc) {
      touch(collection, entityId);
      final map = fields.putIfAbsent('$collection/$entityId', () => {});
      final existing = map[field];
      if (existing == null || existing.hlc < hlc) {
        map[field] = ClockedValue(value, hlc);
      }
    }

    void addTombstone(String collection, String entityId, Hlc hlc) {
      touch(collection, entityId);
      final ref = '$collection/$entityId';
      final existing = tombstones[ref];
      if (existing == null || existing < hlc) tombstones[ref] = hlc;
    }

    final block = page.block ?? base?.block;
    if (block == null) return const [];

    for (final entry in block) {
      if (entry.isTombstone) {
        addTombstone(entry.collection, entry.entityId, entry.hlc);
      } else if (entry.hasCarriedValue) {
        addField(entry.collection, entry.entityId, entry.field,
            entry.carriedValue, entry.hlc);
      }
    }

    if (key.kind == VaultPageKind.outcome) {
      final rootTombstoned = block.any((entry) =>
          entry.isTombstone &&
          entry.collection == todosCollection &&
          entry.entityId == key.entityId);
      if (!rootTombstoned) {
        if (page.frontmatter['deleted'] != null) {
          addTombstone(todosCollection, key.entityId, _host.mintClock());
        } else {
          _readOutcomeFields(key, page, block, addField);
          _readChecklist(key, page, block, addField, addTombstone);
        }
      }
    }

    return [
      for (final ref in refs.entries)
        Change(
          collection: ref.value.collection,
          entityId: ref.value.entityId,
          fields: fields[ref.key] ?? const {},
          tombstone: tombstones[ref.key],
        ),
    ];
  }

  void _readOutcomeFields(
    VaultPageKey key,
    PageModel page,
    List<BlockEntry> block,
    void Function(String, String, String, Object?, Hlc) addField,
  ) {
    String? text(Object? raw) => raw is String && raw.isNotEmpty ? raw : null;
    final notes = page.notes.endsWith('\n')
        ? page.notes.substring(0, page.notes.length - 1)
        : page.notes;
    final onPage = <String, String?>{
      'title': text(page.frontmatter['title']),
      'intent': text(page.frontmatter['intent']),
      'due_date': text(page.frontmatter['due']),
      'notes': text(notes),
    };
    for (final field in onPage.entries) {
      final value = field.value;
      BlockEntry? entry;
      for (final candidate in block) {
        if (candidate.collection == todosCollection &&
            candidate.entityId == key.entityId &&
            candidate.field == field.key) {
          entry = candidate;
        }
      }
      if (entry == null) {
        if (value != null) {
          addField(todosCollection, key.entityId, field.key, value,
              _host.mintClock());
        }
        continue;
      }
      final matches = digestOf(value) == entry.digest ||
          (value == null &&
              (entry.digest == digestOf(null) || entry.digest == digestOf('')));
      if (matches) {
        // An empty field is still a field: its clock must reach the host, or a
        // device that only sees the page would lack it and write other bytes.
        final carried =
            value ?? (entry.digest == digestOf('') ? '' : null);
        addField(
            todosCollection, key.entityId, field.key, carried, entry.hlc);
      } else {
        addField(todosCollection, key.entityId, field.key, value,
            _host.mintClock());
      }
    }
  }

  void _readChecklist(
    VaultPageKey key,
    PageModel page,
    List<BlockEntry> block,
    void Function(String, String, String, Object?, Hlc) addField,
    void Function(String, String, Hlc) addTombstone,
  ) {
    // The Actions the block knows, as they were rendered: current, planned,
    // done; then by position; then by id.
    final tombstoned = {
      for (final entry in block)
        if (entry.isTombstone && entry.collection == actionsCollection)
          entry.entityId,
    };
    final known = <String, Map<String, Object?>>{};
    for (final entry in block) {
      if (entry.collection != actionsCollection ||
          entry.isTombstone ||
          tombstoned.contains(entry.entityId) ||
          !entry.hasCarriedValue) {
        continue;
      }
      (known[entry.entityId] ??= {})[entry.field] = entry.carriedValue;
    }
    int rank(Object? role) => switch (role) {
          'current' => 0,
          'planned' => 1,
          'done' => 2,
          _ => 3,
        };
    final rendered = known.entries
        .where((entry) =>
            rank(entry.value['role']) < 3 && entry.value['text'] is String)
        .toList()
      ..sort((a, b) {
        final byRank = rank(a.value['role']).compareTo(rank(b.value['role']));
        if (byRank != 0) return byRank;
        final byPosition = ((a.value['position'] as int?) ?? 0)
            .compareTo((b.value['position'] as int?) ?? 0);
        return byPosition != 0 ? byPosition : a.key.compareTo(b.key);
      });

    final lines = page.checklist;
    final matchOfLine = List<int?>.filled(lines.length, null);
    final used = <int>{};
    for (var i = 0; i < lines.length; i++) {
      for (var k = 0; k < rendered.length; k++) {
        if (!used.contains(k) && rendered[k].value['text'] == lines[i].text) {
          matchOfLine[i] = k;
          used.add(k);
          break;
        }
      }
    }
    for (var i = 0; i < lines.length; i++) {
      if (matchOfLine[i] == null && i < rendered.length && !used.contains(i)) {
        matchOfLine[i] = i;
        used.add(i);
      }
    }

    String? userId;
    for (final entry in block) {
      if (entry.collection == todosCollection &&
          entry.entityId == key.entityId &&
          entry.field == 'user_id' &&
          entry.carriedValue is String) {
        userId = entry.carriedValue! as String;
      }
    }

    final newOrdinals = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final matched = matchOfLine[i];
      if (matched != null) {
        final actionId = rendered[matched].key;
        final fields = rendered[matched].value;
        if (fields['text'] != line.text) {
          addField(actionsCollection, actionId, 'text', line.text,
              _host.mintClock());
        }
        final wasDone = fields['role'] == 'done';
        if (line.done && !wasDone) {
          final clock = _host.mintClock();
          addField(actionsCollection, actionId, 'role', 'done', clock);
          addField(actionsCollection, actionId, 'done_at',
              encodeInstant(_instantOf(clock)), clock);
        } else if (!line.done && wasDone) {
          final clock = _host.mintClock();
          addField(actionsCollection, actionId, 'role', 'planned', clock);
          addField(actionsCollection, actionId, 'position', i, clock);
        }
      } else if (userId != null) {
        final ordinal = newOrdinals.update(line.text, (count) => count + 1,
            ifAbsent: () => 0);
        final actionId =
            vaultHandEditedActionIdFor(key.entityId, line.text, ordinal);
        final clock = _host.mintClock();
        addField(actionsCollection, actionId, 'outcome_id', key.entityId, clock);
        addField(actionsCollection, actionId, 'user_id', userId, clock);
        addField(actionsCollection, actionId, 'text', line.text, clock);
        addField(actionsCollection, actionId, 'role',
            line.done ? 'done' : 'planned', clock);
        addField(actionsCollection, actionId, 'position', i, clock);
        addField(actionsCollection, actionId, 'created_at',
            encodeInstant(_instantOf(clock)), clock);
        if (line.done) {
          addField(actionsCollection, actionId, 'done_at',
              encodeInstant(_instantOf(clock)), clock);
        }
      }
    }
    // A line that is gone, for an Action the block knows, is a deletion. A stale
    // copy lacks both the line and the block entry, so it deletes nothing.
    for (var k = 0; k < rendered.length; k++) {
      if (!used.contains(k)) {
        addTombstone(actionsCollection, rendered[k].key, _host.mintClock());
      }
    }
  }

  DateTime _instantOf(Hlc clock) =>
      DateTime.fromMillisecondsSinceEpoch(clock.wallMs, isUtc: true);

  // --- writing a page --------------------------------------------------------

  Future<void> _writePage(VaultPageKey key) async {
    var attempts = 0;
    while (true) {
      final text = await _render(key);
      if (text == null) return;
      final path = await _pathFor(key, text);
      final existing = await _folder.read(path);
      final base = await _baseOf(path);
      if (existing == text) {
        if (base != text) await _saveBase(path, text);
        return;
      }
      if (existing != null && existing != base && attempts < 2) {
        // Someone changed the file since this device last saw it: read it before
        // it is overwritten.
        final PageModel page;
        try {
          page = parsePage(existing);
        } on PageParseException catch (error) {
          debugPrint('vault: $path left alone: ${error.message}');
          return;
        }
        if (page.frontmatter['id'] is! String) return;
        await _ingest(key, path, existing, page);
        attempts++;
        continue;
      }
      await _folder.writeAtomically(path, text);
      await _saveBase(path, text);
      _paths[key] = path;
      return;
    }
  }

  Future<String?> _render(VaultPageKey key) async {
    final members = _members[key];
    if (members == null || members.isEmpty) return null;
    final changes = <Change>[];
    for (final ref in members.toList()..sort()) {
      final slash = ref.indexOf('/');
      final change = await _host.mergedEntity(
          ref.substring(0, slash), ref.substring(slash + 1));
      if (change.fields.isEmpty && change.tombstone == null) continue;
      changes.add(change);
    }
    if (changes.isEmpty) return null;
    return renderPage(layOutPage(key, changes));
  }

  Future<String> _pathFor(VaultPageKey key, String text) async {
    final known = _paths[key];
    if (known != null) return known;
    final page = parsePage(text);
    final String stem;
    switch (key.kind) {
      case VaultPageKind.outcome:
        stem = _slug(page.frontmatter['title']);
      case VaultPageKind.session:
        final started = page.frontmatter['started'];
        final date = started is String && started.length >= 10
            ? started.substring(0, 10)
            : 'undated';
        stem = '$date-${key.entityId}';
      case VaultPageKind.capture:
        stem = key.entityId;
    }
    var candidate = '${key.kind.folder}/$stem.md';
    final existing = await _folder.read(candidate);
    if (existing != null) {
      String? otherId;
      try {
        final id = parsePage(existing).frontmatter['id'];
        otherId = id is String ? id : null;
      } on PageParseException {
        otherId = null;
      }
      if (otherId != key.entityId) {
        final short = key.entityId.length > 8
            ? key.entityId.substring(0, 8)
            : key.entityId;
        candidate = '${key.kind.folder}/$stem-$short.md';
      }
    }
    return candidate;
  }

  String _slug(Object? title) {
    final raw = title is String ? title.toLowerCase() : '';
    final slug = raw
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return 'untitled';
    return slug.length > 60 ? slug.substring(0, 60) : slug;
  }

  // --- base copies -----------------------------------------------------------

  Future<String?> _baseOf(String path) async {
    final row = await _sync.customSelect(
      'SELECT page_text FROM vault_page_bases WHERE page_path = ?',
      variables: [Variable<String>(path)],
    ).getSingleOrNull();
    return row?.read<String>('page_text');
  }

  Future<void> _saveBase(String path, String text) => _sync.customStatement(
        'INSERT OR REPLACE INTO vault_page_bases (page_path, page_text) VALUES (?, ?)',
        [path, text],
      );

  Future<void> _dropBase(String path) => _sync.customStatement(
      'DELETE FROM vault_page_bases WHERE page_path = ?', [path]);
}
