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

import '../../database/tables.dart';
import '../../models/intent.dart';
import '../collection_codecs.dart';
import '../hlc.dart';
import '../host/change.dart';
import '../host/sync_host.dart';
import '../ids.dart';
import '../sync_database.dart';
import 'page_codec.dart';
import 'page_layout.dart';
import 'page_tags.dart';
import 'vault_folder.dart';
import 'vault_health.dart';

class VaultPlugin implements SyncPlugin {
  VaultPlugin({required VaultFolder folder, required SyncDatabase sync})
      : _folder = folder,
        _sync = sync;

  static const String pluginId = 'vault';

  final VaultFolder _folder;
  final SyncDatabase _sync;
  late SyncHost _host;
  final StreamController<VaultHealth> _health = StreamController.broadcast();

  /// Pages in the folder the app could not read or parse, and left alone.
  int _unreadablePageCount = 0;

  /// Pages the last read pass could not take into the host, and left alone.
  /// Their content is in the folder and nowhere else: the host refused it.
  int _untakenPageCount = 0;

  /// The pages the last read pass could not take. A page is here while a copy
  /// of it still holds an edit the app does not have, so it is not written
  /// over: the folder keeps that edit until the host takes it.
  final Set<VaultPageKey> _untaken = {};

  /// Whether the folder could be reached in the last pass.
  bool _folderReachable = true;

  /// Entities on each page: `collection/entityId`. Built from the host's
  /// snapshot at start and grown by every delivery and every page read.
  final Map<VaultPageKey, Set<String>> _members = {};
  final Map<VaultPageKey, String> _paths = {};
  Future<void> _tail = Future<void>.value();

  @override
  String get id => pluginId;

  @override
  Stream<VaultHealth> get health => _health.stream;

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

  void _reportSynced() => _health.add(VaultHealth(
        lastSyncedAt: DateTime.now().toUtc(),
        unreadablePageCount: _unreadablePageCount,
        untakenPageCount: _untakenPageCount,
        folderReachable: _folderReachable,
      ));

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
    _unreadablePageCount = 0;
    _untakenPageCount = 0;
    _untaken.clear();
    _folderReachable = true;
    for (final kind in VaultPageKind.values) {
      final byId = <String, List<({String path, String text, PageModel page})>>{};
      final List<String> paths;
      try {
        paths = await _folder.listMarkdownFiles(kind.folder);
      } on Object catch (error) {
        // A folder that cannot be listed is reported and left alone: the other
        // folders are still read, and nothing is written over.
        _folderReachable = false;
        debugPrint('vault: ${kind.folder} not listed: $error');
        continue;
      }
      for (final path in paths) {
        final String? text;
        try {
          text = await _folder.read(path);
        } on Object catch (error) {
          // A file that cannot be read is left alone: the rest of the folder
          // is still read. It is counted, so the failure is reported.
          _unreadablePageCount++;
          debugPrint('vault: $path not read: $error');
          continue;
        }
        if (text == null) continue;
        final PageModel page;
        try {
          page = parsePage(text);
        } on PageParseException catch (error) {
          // A page that does not parse is never written over. It is counted,
          // so a page the app cannot read is reported rather than silent.
          _unreadablePageCount++;
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
        // A copy the host would not take is kept: its content is in the folder
        // and nowhere else, and the app does not have it.
        final untaken = <String>{};
        for (final copy in copies) {
          if (copy.text != await _baseOf(copy.path)) {
            if (await _ingest(key, copy.path, copy.text, copy.page)) {
              touched.add(key);
            } else {
              untaken.add(copy.path);
            }
          }
        }
        if (untaken.isNotEmpty) {
          // The page still holds an edit the app does not have, so it is not
          // written over either: the folder keeps it until the host takes it.
          _untakenPageCount++;
          _untaken.add(key);
        }
        _paths[key] = copies.first.path;
        _members.putIfAbsent(key, () => <String>{});
        // Concurrent versions of one page were all read; keep one.
        for (final extra in copies.skip(1)) {
          if (untaken.contains(extra.path)) {
            // The host did not take this copy, so it still holds an edit the
            // app does not have. It stays until the host takes it.
            continue;
          }
          try {
            await _folder.remove(extra.path);
          } on Object catch (error) {
            debugPrint('vault: ${extra.path} not removed: $error');
            continue;
          }
          await _dropBase(extra.path);
          touched.add(key);
        }
      }
    }
    return touched;
  }

  /// Take what a page says. Returns false when the page could not be taken:
  /// it is left alone, and the next pass reads it again.
  Future<bool> _ingest(
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
      try {
        await _host.applyRemote(id, changes);
      } on Object catch (error) {
        // A page the app cannot take must not stop the vault: the other pages
        // are still read, and this one is left for the next pass.
        debugPrint('vault: $path not taken: $error');
        return false;
      }
      final members = _members.putIfAbsent(key, () => <String>{});
      for (final change in changes) {
        members.add('${change.collection}/${change.entityId}');
        final tagId = linkedTagId(change);
        if (tagId != null) members.add('$tagsCollection/$tagId');
      }
    }
    await _saveBase(path, text);
    return true;
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
      // No clock is compared here. The host's merge settles every field, and
      // the page read below is the last word on what the page says: it knows
      // whether a value is what a device wrote (its digest says so) or a hand
      // edit, and a hand edit gets a clock of its own.
      final map = fields.putIfAbsent('$collection/$entityId', () => {});
      map[field] = ClockedValue(value, hlc);
    }

    void addTombstone(String collection, String entityId, Hlc hlc) {
      touch(collection, entityId);
      tombstones['$collection/$entityId'] = hlc;
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

    if (key.kind == VaultPageKind.capture) {
      final rootTombstoned = block.any((entry) =>
          entry.isTombstone &&
          entry.collection == capturesCollection &&
          entry.entityId == key.entityId);
      if (!rootTombstoned) {
        _readCaptureFields(key, page, block, addField);
      }
    }

    // The Labels and the Area the page shows.
    for (final change in tagLinkChanges(
      key: key,
      page: page,
      block: block,
      mintClock: _host.mintClock,
    )) {
      for (final entry in change.fields.entries) {
        addField(change.collection, change.entityId, entry.key,
            entry.value.value, entry.value.hlc);
      }
      final tombstone = change.tombstone;
      if (tombstone != null) {
        addTombstone(change.collection, change.entityId, tombstone);
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
        // Nothing said about it before: what the page shows is news.
        if (value != null && _canCarry(todosCollection, field.key, value)) {
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
      } else if (_canCarry(todosCollection, field.key, value)) {
        // A hand edit, and one the app can hold.
        addField(todosCollection, key.entityId, field.key, value,
            _host.mintClock());
      } else {
        // A hand edit the app cannot hold. It is not carried, so the app keeps
        // the value it has, and the next write puts the page back.
        debugPrint('vault: ${field.key} not taken: the app cannot hold it');
      }
    }
  }

  void _readCaptureFields(
    VaultPageKey key,
    PageModel page,
    List<BlockEntry> block,
    void Function(String, String, String, Object?, Hlc) addField,
  ) {
    final raw = page.frontmatter['clarified_at'];
    final value = raw is String && raw.isNotEmpty ? raw : null;
    BlockEntry? entry;
    for (final candidate in block) {
      if (candidate.collection == capturesCollection &&
          candidate.entityId == key.entityId &&
          candidate.field == 'clarified_at') {
        entry = candidate;
      }
    }
    if (entry == null) {
      // Nothing said about it before: what the page shows is news.
      if (value != null &&
          _canCarry(capturesCollection, 'clarified_at', value)) {
        addField(capturesCollection, key.entityId, 'clarified_at', value,
            _host.mintClock());
      }
      return;
    }
    if (digestOf(value) == entry.digest) {
      // What a device wrote at that clock. Its clock still has to reach the
      // host, or a device that only sees the page would lack it.
      addField(capturesCollection, key.entityId, 'clarified_at', value,
          entry.hlc);
    } else if (_canCarry(capturesCollection, 'clarified_at', value)) {
      // A hand edit.
      addField(capturesCollection, key.entityId, 'clarified_at', value,
          _host.mintClock());
    } else {
      // A hand edit the app cannot hold: it is not carried, and the next
      // write puts the page back.
      debugPrint('vault: clarified_at not taken: the app cannot hold it');
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

    // The planned Actions, in the order the page shows them. `position` is
    // dense among the planned Actions of an Outcome, so the current Action and
    // the done ones take none.
    final planned = <({String actionId, int? mergedPosition})>[];
    final placedLast = <({String actionId, int? mergedPosition})>[];

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
          // A done Action is not in the queue any more.
          if (fields['position'] != null) {
            addField(actionsCollection, actionId, 'position', null, clock);
          }
        } else if (!line.done && wasDone) {
          // Un-ticking puts the Action back at the end of the queue.
          addField(actionsCollection, actionId, 'role', 'planned',
              _host.mintClock());
          placedLast.add((
            actionId: actionId,
            mergedPosition: fields['position'] as int?,
          ));
        } else if (!line.done && fields['role'] == 'planned') {
          planned.add((
            actionId: actionId,
            mergedPosition: fields['position'] as int?,
          ));
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
        addField(actionsCollection, actionId, 'created_at',
            encodeInstant(_instantOf(clock)), clock);
        if (line.done) {
          addField(actionsCollection, actionId, 'done_at',
              encodeInstant(_instantOf(clock)), clock);
        } else {
          planned.add((actionId: actionId, mergedPosition: null));
        }
      }
    }
    // The positions the order on the page means.
    var position = 0;
    for (final action in [...planned, ...placedLast]) {
      if (action.mergedPosition != position) {
        addField(actionsCollection, action.actionId, 'position', position,
            _host.mintClock());
      }
      position++;
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
    if (_untaken.contains(key)) {
      // The host did not take what this page says, so a copy of it still holds
      // an edit the app does not have. Writing the merged state over it would
      // lose that edit: the page is left alone until the host takes it.
      return;
    }
    var attempts = 0;
    while (true) {
      final text = await _render(key);
      if (text == null) return;
      var path = _pathFor(key, text);
      final String? existing;
      try {
        existing = await _folder.read(path);
      } on Object catch (error) {
        // A file that cannot be read is left alone: the other pages are still
        // written.
        debugPrint('vault: $path not read: $error');
        return;
      }
      final base = await _baseOf(path);
      if (existing == text) {
        if (base != text) await _saveBase(path, text);
        _paths[key] = path;
        return;
      }
      if (existing != null) {
        // What is at this path?
        final PageModel page;
        try {
          page = parsePage(existing);
        } on PageParseException catch (error) {
          debugPrint('vault: $path left alone: ${error.message}');
          return;
        }
        final id = page.frontmatter['id'];
        if (id is! String) {
          debugPrint('vault: $path left alone: it names no entity');
          return;
        }
        if (id != key.entityId) {
          // The path holds another entity's page. This entity needs a path of
          // its own — one every device derives the same way — and the other
          // entity's page is left alone.
          final own = _ownPath(key, path);
          if (own == path) {
            debugPrint('vault: $path left alone: another entity holds it');
            return;
          }
          path = own;
          _paths[key] = path;
          attempts++;
          continue;
        }
        if (existing != base && attempts < 3) {
          // Someone changed the file since this device last saw it: read it
          // before it is overwritten.
          if (!await _ingest(key, path, existing, page)) {
            // The host would not take it, so the file still holds an edit the
            // app does not have. It is not written over.
            _untaken.add(key);
            return;
          }
          attempts++;
          continue;
        }
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

  /// Where this entity's page goes: where it went last, or a name of its own.
  ///
  /// The name is a reading of the entity, never its identity — the frontmatter
  /// id is. Two entities can want the same name, and the one that finds the
  /// name taken moves to a path of its own ([_ownPath]).
  String _pathFor(VaultPageKey key, String text) {
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
    return '${key.kind.folder}/$stem.md';
  }

  /// A path of this entity's own, for when the path it wanted holds another
  /// entity's page.
  ///
  /// Derived from the entity's id, so every device that meets the same
  /// collision derives the same path.
  String _ownPath(VaultPageKey key, String path) {
    final suffix = '-${key.entityId}';
    final stem =
        path.endsWith('.md') ? path.substring(0, path.length - 3) : path;
    if (stem.endsWith(suffix)) return path;
    return '$stem$suffix.md';
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

/// Whether the app can hold [value] as [field] of [collection].
///
/// A hand edit is a value no device wrote, so it can be one the app cannot
/// hold: a value of the wrong kind, an Outcome's intent that is not one of
/// its three words, a title longer than the row allows. Carrying such a value
/// would put a row the domain store refuses into the sync store, and the
/// Outcome would vanish from the app.
///
/// Such a value is not carried. The app keeps the value it has, and the next
/// write puts the page back.
bool _canCarry(String collection, String field, Object? value) {
  if (value == null) {
    // A field cleared by hand is a value the app can hold — unless the row
    // cannot do without it. `todos.intent` is NOT NULL, and a null intent
    // would put a row the store refuses into the sync store.
    return !(collection == todosCollection && field == 'intent');
  }
  final kind = collectionCodecs[collection]?.columns[field];
  final fits = switch (kind) {
    FieldKind.text => value is String,
    FieldKind.integer => value is num,
    FieldKind.boolean => value is bool || value is int,
    FieldKind.instant => value is String && decodeInstant(value) != null,
    null => true,
  };
  if (!fits) return false;
  // The rules the column contract does not carry.
  if (collection == todosCollection && field == 'intent') {
    return Intent.values.any((intent) => intent.value == value);
  }
  if (collection == todosCollection && field == 'title') {
    return value is String && value.length <= Todos.maxTitleLength;
  }
  return true;
}
