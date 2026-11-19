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

  /// The pages the last read pass could not read at all. A copy of such a
  /// page holds content the app cannot reach, so it is not written over
  /// either.
  final Set<VaultPageKey> _unreadable = {};

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
    _unreadable.clear();
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
        // and nowhere else, and the app does not have it. So is a copy the app
        // cannot read at all.
        final untaken = <String>{};
        final unreadable = <String>{};
        // The copy the app holds: the first one it took, or the one it already
        // had. A copy the app could not take is never the page it writes to.
        String? held;
        for (final copy in copies) {
          if (copy.text == await _baseOf(copy.path)) {
            held ??= copy.path;
            continue;
          }
          final outcome = await _ingest(key, copy.path, copy.text, copy.page);
          switch (outcome) {
            case _Ingest.taken:
              touched.add(key);
              held ??= copy.path;
            case _Ingest.refused:
              untaken.add(copy.path);
            case _Ingest.unreadable:
              unreadable.add(copy.path);
          }
        }
        if (unreadable.isNotEmpty) {
          // A copy the app cannot read holds content the app cannot reach, so
          // it is left alone: never removed, never written over.
          _unreadablePageCount++;
          _unreadable.add(key);
        }
        if (untaken.isNotEmpty) {
          // The page still holds an edit the app does not have, so it is not
          // written over either: the folder keeps it until the host takes it.
          _untakenPageCount++;
          _untaken.add(key);
        }
        _paths[key] = held ?? copies.first.path;
        _members.putIfAbsent(key, () => <String>{});
        // Concurrent versions of one page were all read; keep one.
        for (final extra in copies) {
          if (extra.path == held) continue;
          if (untaken.contains(extra.path)) {
            // The host did not take this copy, so it still holds an edit the
            // app does not have. It stays until the host takes it.
            continue;
          }
          if (unreadable.contains(extra.path)) {
            // The app cannot read this copy, so it cannot say that the copy it
            // holds says the same thing. It stays.
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

  /// Take what a page says. Returns what the read ended in: the page is left
  /// alone unless the host took all of it.
  Future<_Ingest> _ingest(
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
    final List<Change> carried;
    try {
      carried = _carriedChanges(key, page, baseModel);
    } on _UnreadablePage catch (error) {
      // A page the app cannot read is left alone: the other pages are still
      // read, and this one is read again on the next pass.
      debugPrint('vault: $path not read: ${error.reason}');
      return _Ingest.unreadable;
    }
    if (carried.isNotEmpty) {
      try {
        await _host.applyRemote(id, carried);
      } on Object catch (error) {
        // A page the app cannot take must not stop the vault: the other pages
        // are still read, and this one is left for the next pass.
        debugPrint('vault: $path not taken: $error');
        return _Ingest.refused;
      }
      _rememberMembers(key, carried);
    }
    // The hand edits are read after the carried changes have reached the host:
    // the host has then observed the page's own clocks, and the clock a hand
    // edit is stamped with is later than every clock the page carries.
    final List<Change> handEdits;
    try {
      handEdits = _handEditChanges(key, page, baseModel);
    } on _UnreadablePage catch (error) {
      debugPrint('vault: $path not read: ${error.reason}');
      return _Ingest.unreadable;
    }
    if (handEdits.isNotEmpty) {
      try {
        await _host.applyRemote(id, handEdits);
      } on Object catch (error) {
        debugPrint('vault: $path not taken: $error');
        return _Ingest.refused;
      }
      _rememberMembers(key, handEdits);
    }
    await _saveBase(path, text);
    return _Ingest.taken;
  }

  /// The entities a page's changes touch, so the page knows what is on it.
  void _rememberMembers(VaultPageKey key, List<Change> changes) {
    final members = _members.putIfAbsent(key, () => <String>{});
    for (final change in changes) {
      members.add('${change.collection}/${change.entityId}');
      final tagId = linkedTagId(change);
      if (tagId != null) members.add('$tagsCollection/$tagId');
    }
  }

  /// What a page carries, with the clocks it carries.
  ///
  /// The block's own entries, and the values the page shows that still match
  /// the digest the block holds: what a device wrote at that clock. No clock
  /// is minted here — every clock is the one the page carries.
  List<Change> _carriedChanges(
      VaultPageKey key, PageModel page, PageModel? base) {
    final block = _usableBlock(page, base);
    _validateCarriedPositions(block);
    final fields = <String, Map<String, ClockedValue>>{};
    final tombstones = <String, Hlc>{};

    void carry(String collection, String entityId, String field, Object? value,
        Hlc hlc) {
      fields
          .putIfAbsent('$collection/$entityId', () => <String, ClockedValue>{})
          [field] = ClockedValue(value, hlc);
    }

    for (final entry in block) {
      if (entry.isTombstone) {
        tombstones['${entry.collection}/${entry.entityId}'] = entry.hlc;
      } else if (entry.hasCarriedValue) {
        carry(entry.collection, entry.entityId, entry.field, entry.carriedValue,
            entry.hlc);
      }
    }

    // The values the page shows that the block's clock stamped.
    if (key.kind == VaultPageKind.outcome) {
      for (final field in _shownOutcomeFields(page).entries) {
        final entry =
            _entryFor(block, todosCollection, key.entityId, field.key);
        if (entry == null || !_matchesDigest(field.value, entry)) continue;
        // An empty field is still a field: its clock must reach the host, or a
        // device that only sees the page would lack it and write other bytes.
        carry(todosCollection, key.entityId, field.key,
            field.value ?? (entry.digest == digestOf('') ? '' : null),
            entry.hlc);
      }
    }
    if (key.kind == VaultPageKind.capture) {
      final value = _shownValue(page.frontmatter['clarified_at']);
      final entry =
          _entryFor(block, capturesCollection, key.entityId, 'clarified_at');
      if (entry != null && _matchesDigest(value, entry)) {
        carry(capturesCollection, key.entityId, 'clarified_at', value,
            entry.hlc);
      }
    }

    return _changesOf(fields, tombstones);
  }

  /// What a page says that no device wrote: a hand edit, and it gets a clock
  /// of its own.
  ///
  /// No clock is compared here. The host's merge settles every field, and the
  /// page read is the last word on what the page says: it knows whether a
  /// value is what a device wrote (its digest says so) or a hand edit, and a
  /// hand edit gets a clock of its own.
  List<Change> _handEditChanges(
      VaultPageKey key, PageModel page, PageModel? base) {
    final block = _usableBlock(page, base);
    final fields = <String, Map<String, ClockedValue>>{};
    final tombstones = <String, Hlc>{};

    void edit(String collection, String entityId, String field, Object? value,
        Hlc hlc) {
      fields
          .putIfAbsent('$collection/$entityId', () => <String, ClockedValue>{})
          [field] = ClockedValue(value, hlc);
    }

    void remove(String collection, String entityId, Hlc hlc) {
      tombstones['$collection/$entityId'] = hlc;
    }

    if (key.kind == VaultPageKind.outcome) {
      if (!_isTombstoned(block, todosCollection, key.entityId)) {
        if (page.frontmatter['deleted'] != null) {
          remove(todosCollection, key.entityId, _host.mintClock());
        } else {
          _handEditedOutcomeFields(key, page, block, edit);
          _readChecklist(key, page, block, edit, remove);
        }
      }
    }

    if (key.kind == VaultPageKind.capture) {
      if (!_isTombstoned(block, capturesCollection, key.entityId)) {
        _handEditedCaptureField(key, page, block, edit);
      }
    }

    // The Labels and the Area the page shows. A frozen page is not reconciled:
    // a hand edit to a deleted page creates no Tag and no link.
    if (!_frozen(key, page, block)) {
      for (final change in tagLinkChanges(
        key: key,
        page: page,
        block: block,
        mintClock: _host.mintClock,
      )) {
        for (final entry in change.fields.entries) {
          edit(change.collection, change.entityId, entry.key, entry.value.value,
              entry.value.hlc);
        }
        final tombstone = change.tombstone;
        if (tombstone != null) {
          remove(change.collection, change.entityId, tombstone);
        }
      }
    }

    return _changesOf(fields, tombstones);
  }

  /// Whether the page is frozen: its entity is deleted.
  ///
  /// A deleted page keeps its last content and gains a deletion date. Nothing
  /// a person types into it is taken: the page is not read, only what the
  /// block carries.
  bool _frozen(VaultPageKey key, PageModel page, List<BlockEntry> block) {
    switch (key.kind) {
      case VaultPageKind.outcome:
        return _isTombstoned(block, todosCollection, key.entityId) ||
            page.frontmatter['deleted'] != null;
      case VaultPageKind.capture:
        return _isTombstoned(block, capturesCollection, key.entityId);
      case VaultPageKind.session:
        return false;
    }
  }

  /// The changes of the entities a page's read touched.
  List<Change> _changesOf(Map<String, Map<String, ClockedValue>> fields,
      Map<String, Hlc> tombstones) {
    final entities = {...fields.keys, ...tombstones.keys}.toList()..sort();
    return [
      for (final ref in entities)
        Change(
          collection: ref.substring(0, ref.indexOf('/')),
          entityId: ref.substring(ref.indexOf('/') + 1),
          fields: fields[ref] ?? const {},
          tombstone: tombstones[ref],
        ),
    ];
  }

  /// The values an Outcome page shows, as the page says them.
  Map<String, Object?> _shownOutcomeFields(PageModel page) {
    final notes = page.notes.endsWith('\n')
        ? page.notes.substring(0, page.notes.length - 1)
        : page.notes;
    return {
      'title': _shownValue(page.frontmatter['title']),
      'intent': _shownValue(page.frontmatter['intent']),
      'due_date': _shownValue(page.frontmatter['due']),
      'notes': notes.isEmpty ? null : notes,
    };
  }

  /// The values the page shows that no device wrote: a hand edit, and one the
  /// app can hold.
  void _handEditedOutcomeFields(
    VaultPageKey key,
    PageModel page,
    List<BlockEntry> block,
    void Function(String, String, String, Object?, Hlc) edit,
  ) {
    for (final field in _shownOutcomeFields(page).entries) {
      final value = field.value;
      final entry =
          _entryFor(block, todosCollection, key.entityId, field.key);
      if (entry != null && _matchesDigest(value, entry)) {
        // What a device wrote at that clock: it has already passed through.
        continue;
      }
      if (entry == null && value == null) {
        // Nothing said about it before, and nothing shown: no news.
        continue;
      }
      if (_canCarry(todosCollection, field.key, value)) {
        edit(todosCollection, key.entityId, field.key, value,
            _host.mintClock());
      } else {
        // A hand edit the app cannot hold. It is not carried, so the app keeps
        // the value it has, and the next write puts the page back.
        debugPrint('vault: ${field.key} not taken: the app cannot hold it');
      }
    }
  }

  /// The Capture's clarification, when no device wrote it.
  void _handEditedCaptureField(
    VaultPageKey key,
    PageModel page,
    List<BlockEntry> block,
    void Function(String, String, String, Object?, Hlc) edit,
  ) {
    final value = _shownValue(page.frontmatter['clarified_at']);
    final entry =
        _entryFor(block, capturesCollection, key.entityId, 'clarified_at');
    if (entry != null && _matchesDigest(value, entry)) {
      // What a device wrote at that clock: it has already passed through.
      return;
    }
    if (entry == null && value == null) {
      // Nothing said about it before, and nothing shown: no news.
      return;
    }
    if (_canCarry(capturesCollection, 'clarified_at', value)) {
      edit(capturesCollection, key.entityId, 'clarified_at', value,
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
    if (_untaken.contains(key) || _unreadable.contains(key)) {
      // The host did not take what this page says, so a copy of it still holds
      // an edit the app does not have. Writing the merged state over it would
      // lose that edit: the page is left alone until the host takes it. A page
      // the app cannot read is left alone for the same reason.
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
          final outcome = await _ingest(key, path, existing, page);
          if (outcome != _Ingest.taken) {
            // The host would not take it, so the file still holds an edit the
            // app does not have. It is not written over.
            if (outcome == _Ingest.refused) {
              _untaken.add(key);
            } else {
              _unreadable.add(key);
            }
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

/// What a page's read ended in.
enum _Ingest {
  /// The host took everything the page said. The page's base copy is saved,
  /// and the page may be written over.
  taken,

  /// The host refused a change. The page still holds something the app does
  /// not have, so it is kept and read again on the next pass.
  refused,

  /// The app cannot read the page: there is no usable block, and nothing to
  /// read it with. The page holds content the app cannot reach, so it is kept
  /// and read again on the next pass.
  unreadable,
}

/// The block a page is read with: its own, or the base copy's when the page's
/// is missing or mangled.
///
/// Throws [_UnreadablePage] when neither can be used: there is nothing to read
/// the page with, and nothing that says what it holds.
List<BlockEntry> _usableBlock(PageModel page, PageModel? base) {
  final block = page.block ?? base?.block;
  if (block == null) {
    throw _UnreadablePage('the page holds no block that can be read');
  }
  return block;
}

/// The block's entry for one field of one entity, or null when the block says
/// nothing about it.
BlockEntry? _entryFor(
    List<BlockEntry> block, String collection, String entityId, String field) {
  BlockEntry? found;
  for (final entry in block) {
    if (entry.collection == collection &&
        entry.entityId == entityId &&
        entry.field == field) {
      found = entry;
    }
  }
  return found;
}

/// Whether the value a page shows is the one the block's clock stamped.
///
/// A value that matches its digest is what a device wrote at that clock; one
/// that does not is a hand edit.
bool _matchesDigest(Object? value, BlockEntry entry) =>
    digestOf(value) == entry.digest ||
    (value == null &&
        (entry.digest == digestOf(null) || entry.digest == digestOf('')));

/// Whether the block says the entity is gone.
bool _isTombstoned(
    List<BlockEntry> block, String collection, String entityId) {
  for (final entry in block) {
    if (entry.isTombstone &&
        entry.collection == collection &&
        entry.entityId == entityId) {
      return true;
    }
  }
  return false;
}

/// The Action positions the block carries, checked before they are read.
///
/// A position that is not a number is a page the app cannot hold: the queue
/// is numbered, and a position the app cannot read is not a position. The
/// page is left alone rather than half-read.
void _validateCarriedPositions(List<BlockEntry> block) {
  for (final entry in block) {
    if (entry.collection != actionsCollection) continue;
    if (entry.field != 'position' || !entry.hasCarriedValue) continue;
    final value = entry.carriedValue;
    if (value != null && value is! int) {
      throw _UnreadablePage(
          'an Action carries a position that is not a number');
    }
  }
}

/// A frontmatter value as the page shows it.
///
/// A key that is absent is a cleared field, and a cleared field is null. A key
/// that is present but holds something else is **not** a cleared field: it is a
/// value the app cannot hold, and it is refused rather than carried as a
/// clear — the app keeps the value it has, and the next write puts the page
/// back.
Object? _shownValue(Object? raw) {
  if (raw == null) return null;
  if (raw is String && raw.isEmpty) return null;
  return raw;
}

/// A page the app cannot read: its block says nothing the app can use.
///
/// The page is left alone — never removed, never written over — and counted,
/// so the failure is reported rather than silent.
class _UnreadablePage implements Exception {
  _UnreadablePage(this.reason);

  final String reason;

  @override
  String toString() => 'UnreadablePage: $reason';
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
    // cannot do without it. `todos.title` and `todos.intent` are NOT NULL, and
    // a null value for either would put a row the store refuses into the sync
    // store: the Outcome would vanish from the app, and every retry would
    // carry the same invalid value again.
    return !(collection == todosCollection &&
        (field == 'title' || field == 'intent'));
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
