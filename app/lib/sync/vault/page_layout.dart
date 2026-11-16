/// Which entities share a vault page, and how merged state becomes a page model.
///
/// Pure: merged [Change]s in, a [PageModel] out. No host, no folder, no clocks
/// compared — the plugin is a carrier, so this file only arranges values the
/// host already settled.
///
/// Three kinds of page: an Outcome page (the Outcome, its Actions, its tag links
/// and the Tags they name, its bypass decisions, its stand-alone TimeLogs), a
/// session sheet (the FocusSession and everything that hangs off it) and an Inbox
/// page (the Capture, its tag hints and links to Outcomes).
library;

import '../collection_codecs.dart';
import '../host/change.dart';
import 'page_codec.dart';

enum VaultPageKind {
  outcome('Outcomes'),
  session('Sessions'),
  capture('Inbox');

  const VaultPageKind(this.folder);

  /// The top-level vault folder pages of this kind live in.
  final String folder;
}

/// Identity of a page: what it is about, never where it sits in the folder.
class VaultPageKey {
  const VaultPageKey(this.kind, this.entityId);

  final VaultPageKind kind;
  final String entityId;

  @override
  bool operator ==(Object other) =>
      other is VaultPageKey && other.kind == kind && other.entityId == entityId;

  @override
  int get hashCode => Object.hash(kind, entityId);

  @override
  String toString() => '${kind.folder}/$entityId';
}

/// The page an entity of [change] belongs on, or null when it has no page of its
/// own (a Tag is carried by every page that links it; preferences stay on the
/// device).
VaultPageKey? pageOwning(Change change) {
  String? field(String name) {
    final value = change.fields[name]?.value;
    return value is String && value.isNotEmpty ? value : null;
  }

  switch (change.collection) {
    case todosCollection:
      return VaultPageKey(VaultPageKind.outcome, change.entityId);
    case actionsCollection:
      final outcome = field('outcome_id');
      return outcome == null ? null : VaultPageKey(VaultPageKind.outcome, outcome);
    case todoTagsCollection:
      final outcome = field('todo_id');
      return outcome == null ? null : VaultPageKey(VaultPageKind.outcome, outcome);
    case outcomeBypassDecisionsCollection:
      final outcome = field('task_id');
      return outcome == null ? null : VaultPageKey(VaultPageKind.outcome, outcome);
    case timeLogsCollection:
      final session = field('focus_session_id');
      if (session != null) return VaultPageKey(VaultPageKind.session, session);
      final outcome = field('task_id');
      return outcome == null ? null : VaultPageKey(VaultPageKind.outcome, outcome);
    case focusSessionsCollection:
      return VaultPageKey(VaultPageKind.session, change.entityId);
    case focusSessionTasksCollection:
    case focusSessionDispositionsCollection:
    case focusSessionPlanningBypassesCollection:
    case focusSessionReschedulesCollection:
      final session = field('focus_session_id');
      return session == null ? null : VaultPageKey(VaultPageKind.session, session);
    case capturesCollection:
      return VaultPageKey(VaultPageKind.capture, change.entityId);
    case captureTagsCollection:
    case captureOutcomesCollection:
      final capture = field('capture_id');
      return capture == null ? null : VaultPageKey(VaultPageKind.capture, capture);
  }
  return null;
}

/// The Tag ids a junction [change] links to, or null for any other entity.
String? linkedTagId(Change change) {
  if (change.collection != todoTagsCollection &&
      change.collection != captureTagsCollection) {
    return null;
  }
  final value = change.fields['tag_id']?.value;
  return value is String ? value : null;
}

/// Fields whose value the page shows, so a hand edit can be told from a copy by
/// its digest. Every other field of every entity travels in the block.
const Map<String, Set<String>> _shownFields = {
  todosCollection: {'title', 'intent', 'due_date', 'notes'},
  actionsCollection: {'text', 'role', 'position'},
  capturesCollection: {'clarified_at'},
  focusSessionsCollection: {'started_at', 'ended_at'},
};

/// Arrange the merged entities of one page.
///
/// [entities] holds every entity that belongs on the page, deleted ones too (a
/// deletion is a tombstone, not absence), and the Tags the page's links name.
PageModel layOutPage(VaultPageKey key, List<Change> entities) {
  final sorted = [...entities]..sort((a, b) {
      final byCollection = a.collection.compareTo(b.collection);
      return byCollection != 0 ? byCollection : a.entityId.compareTo(b.entityId);
    });
  final root = sorted.where((change) =>
      change.entityId == key.entityId &&
      (change.collection == todosCollection ||
          change.collection == focusSessionsCollection ||
          change.collection == capturesCollection));

  final frontmatter = <String, Object>{'id': key.entityId};
  var notes = '';
  final checklist = <ChecklistLine>[];

  Object? rootValue(String field) =>
      root.isEmpty ? null : root.first.fields[field]?.value;

  final tagsById = {
    for (final change in sorted)
      if (change.collection == tagsCollection && change.tombstone == null)
        change.entityId: change,
  };
  List<String> linkedNames(String type) {
    final names = <String>[];
    for (final change in sorted) {
      final tagId = linkedTagId(change);
      if (tagId == null || change.tombstone != null) continue;
      final tag = tagsById[tagId];
      if (tag != null && tag.fields['type']?.value == type) {
        final name = tag.fields['name']?.value;
        if (name is String) names.add(name);
      }
    }
    return names..sort();
  }

  switch (key.kind) {
    case VaultPageKind.outcome:
      final title = rootValue('title');
      if (title is String) frontmatter['title'] = title;
      final intent = rootValue('intent');
      if (intent is String && intent.isNotEmpty) frontmatter['intent'] = intent;
      final due = rootValue('due_date');
      if (due is String) frontmatter['due'] = due;
      final areas = linkedNames('area');
      if (areas.isNotEmpty) frontmatter['area'] = areas.first;
      final labels = linkedNames('label');
      if (labels.isNotEmpty) frontmatter['labels'] = labels;
      final rootChange = root.isEmpty ? null : root.first;
      if (rootChange?.tombstone != null) {
        frontmatter['deleted'] = encodeInstant(DateTime.fromMillisecondsSinceEpoch(
            rootChange!.tombstone!.wallMs,
            isUtc: true))!;
      }
      final notesValue = rootValue('notes');
      notes = notesValue is String && notesValue.isNotEmpty ? '$notesValue\n' : '';
      checklist.addAll(_outcomeChecklist(sorted));
    case VaultPageKind.session:
      final started = rootValue('started_at');
      if (started is String) frontmatter['started'] = started;
      final ended = rootValue('ended_at');
      if (ended is String) frontmatter['ended'] = ended;
      // The Plan, as links to Outcome pages. Read only.
      final plan = sorted
          .where((change) =>
              change.collection == focusSessionTasksCollection &&
              change.tombstone == null)
          .toList()
        ..sort((a, b) {
          final byPosition = ((a.fields['position']?.value as int?) ?? 0)
              .compareTo((b.fields['position']?.value as int?) ?? 0);
          return byPosition != 0 ? byPosition : a.entityId.compareTo(b.entityId);
        });
      for (final row in plan) {
        final taskId = row.fields['task_id']?.value;
        if (taskId is String) {
          checklist.add(ChecklistLine(done: false, text: '[[Outcomes/$taskId]]'));
        }
      }
    case VaultPageKind.capture:
      final title = rootValue('title');
      if (title is String) frontmatter['title'] = title;
      final clarified = rootValue('clarified_at');
      if (clarified is String) frontmatter['clarified_at'] = clarified;
      final areas = linkedNames('area');
      if (areas.isNotEmpty) frontmatter['area'] = areas.first;
      final labels = linkedNames('label');
      if (labels.isNotEmpty) frontmatter['labels'] = labels;
      final body = rootValue('notes');
      notes = body is String && body.isNotEmpty ? '$body\n' : '';
  }

  return PageModel(
    frontmatter: frontmatter,
    notes: notes,
    checklist: checklist,
    block: _blockOf(key, sorted),
  );
}

/// Live Actions as checklist lines: the current one, then planned by position,
/// then done. Superseded Actions have no line and travel in the block.
List<ChecklistLine> _outcomeChecklist(List<Change> sorted) {
  final actions = sorted
      .where((change) =>
          change.collection == actionsCollection && change.tombstone == null)
      .toList();
  int rank(Change action) => switch (action.fields['role']?.value) {
        'current' => 0,
        'planned' => 1,
        'done' => 2,
        _ => 3,
      };
  actions.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byPosition = ((a.fields['position']?.value as int?) ?? 0)
        .compareTo((b.fields['position']?.value as int?) ?? 0);
    return byPosition != 0 ? byPosition : a.entityId.compareTo(b.entityId);
  });
  return [
    for (final action in actions)
      if (rank(action) < 3 && action.fields['text']?.value is String)
        ChecklistLine(
          done: action.fields['role']?.value == 'done',
          text: action.fields['text']!.value! as String,
        ),
  ];
}

List<BlockEntry> _blockOf(VaultPageKey key, List<Change> entities) {
  final entries = <BlockEntry>[];
  for (final change in entities) {
    final shown = change.entityId == key.entityId ||
            change.collection == actionsCollection
        ? _shownFields[change.collection] ?? const <String>{}
        : const <String>{};
    for (final field in change.fields.entries) {
      final isShown = shown.contains(field.key);
      entries.add(BlockEntry(
        collection: change.collection,
        entityId: change.entityId,
        field: field.key,
        hlc: field.value.hlc,
        digest: digestOf(field.value.value),
        hasCarriedValue: !isShown,
        carriedValue: isShown ? null : field.value.value,
      ));
    }
    final tombstone = change.tombstone;
    if (tombstone != null) {
      entries.add(BlockEntry(
        collection: change.collection,
        entityId: change.entityId,
        field: BlockEntry.tombstoneField,
        hlc: tombstone,
        digest: digestOf(null),
      ));
    }
  }
  return entries;
}
