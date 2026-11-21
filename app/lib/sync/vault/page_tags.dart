/// The tag links a page shows: its Labels, and its Area.
///
/// A page names its Labels as a list and its Area as one name. The block
/// carries the links themselves — a junction entity per link, and the Tag each
/// link names — so a name the page shows and the block does not know is a hand
/// edit: the link is created, and a Tag is created for a name no Tag has.
///
/// **A name always yields the same Tag.** The Tag a hand edit brings into being
/// is named after what was typed ([vaultHandEditedTagIdFor]), never after
/// whichever Tag with that name a device happens to hold: two devices reading
/// the same page have to create the same entity, and a lookup would answer
/// differently on each. The reconciler's fold (ADR-0043) is what collapses
/// such a Tag with an app-created Tag of the same name afterwards.
library;

import '../collection_codecs.dart';
import '../host/change.dart';
import '../hlc.dart';
import '../ids.dart';
import '../../database/tables.dart' show labelTagType, retiredLabelTagType;
import 'page_codec.dart';
import 'page_layout.dart';

/// One link between a page's entity and a Tag.
class _Link {
  const _Link({required this.entityId, required this.tagId, required this.name});

  /// The junction entity: its id is the pair, derived.
  final String entityId;

  /// The Tag the link names.
  final String tagId;

  /// The Tag's name — what the page shows.
  final String name;
}

/// What a page's Labels and its Area mean, as changes.
///
/// [block] is the page's machine block — the page's own, or the base copy's
/// when the page's is missing or mangled. [mintClock] stamps a hand edit.
List<Change> tagLinkChanges({
  required VaultPageKey key,
  required PageModel page,
  required List<BlockEntry> block,
  required Hlc Function() mintClock,
}) {
  final isOutcome = key.kind == VaultPageKind.outcome;
  final isCapture = key.kind == VaultPageKind.capture;
  // A session sheet is read only: it names no Tags.
  if (!isOutcome && !isCapture) return const [];

  final junctionCollection =
      isOutcome ? todoTagsCollection : captureTagsCollection;
  final ownerField = isOutcome ? 'todo_id' : 'capture_id';
  final rootCollection = isOutcome ? todosCollection : capturesCollection;

  final fields = <String, Map<String, ClockedValue>>{};
  final tombstones = <String, Hlc>{};

  void addField(String collection, String entityId, String field, Object? value,
      Hlc hlc) {
    // No clock is compared here: the host's merge settles every field. Each
    // field is written once, by the read that knows what the page says.
    final map = fields.putIfAbsent('$collection/$entityId', () => {});
    map[field] = ClockedValue(value, hlc);
  }

  void addTombstone(String collection, String entityId, Hlc hlc) {
    tombstones['$collection/$entityId'] = hlc;
  }

  // The Tags the page names, by id: their name is what the page shows.
  final tagName = <String, String>{};
  final tagType = <String, String>{};
  for (final entry in block) {
    if (entry.collection != tagsCollection || !entry.hasCarriedValue) continue;
    final value = entry.carriedValue;
    if (value is! String) continue;
    if (entry.field == 'name') tagName[entry.entityId] = value;
    if (entry.field == 'type') tagType[entry.entityId] = value;
  }

  // The links the page has: a junction entity, and the Tag it names.
  final linkTag = <String, String>{};
  final deletedLinks = <String>{};
  for (final entry in block) {
    if (entry.collection != junctionCollection) continue;
    if (entry.isTombstone) {
      deletedLinks.add(entry.entityId);
      continue;
    }
    if (entry.field != 'tag_id' || !entry.hasCarriedValue) continue;
    final tagId = entry.carriedValue;
    if (tagId is! String) continue;
    linkTag[entry.entityId] = tagId;
  }

  // The owner of the page's entity: every row the vault creates carries it.
  String? userId;
  for (final entry in block) {
    if (entry.collection != rootCollection) continue;
    if (entry.entityId != key.entityId) continue;
    if (entry.field != 'user_id' || !entry.hasCarriedValue) continue;
    final value = entry.carriedValue;
    if (value is String && value.isNotEmpty) userId = value;
  }

  // What the page shows.
  final shownLabels = <String>[];
  final rawLabels = page.frontmatter['labels'];
  if (rawLabels is List) {
    for (final value in rawLabels) {
      if (value is String && value.trim().isNotEmpty) shownLabels.add(value);
    }
  }
  final rawArea = page.frontmatter['area'];
  final shownArea =
      rawArea is String && rawArea.trim().isNotEmpty ? rawArea : null;

  // The links the page has, by the kind of Tag they name. Person and Context
  // tags travel in the block only: the page does not show them, so it cannot
  // say anything about them.
  final labelLinks = <_Link>[];
  final areaLinks = <_Link>[];
  for (final entry in linkTag.entries) {
    if (deletedLinks.contains(entry.key)) continue;
    final tagId = entry.value;
    final name = tagName[tagId];
    final type = tagType[tagId];
    if (name == null || type == null) continue;
    final link = _Link(entityId: entry.key, tagId: tagId, name: name);
    if (type == labelTagType || type == retiredLabelTagType) {
      labelLinks.add(link);
    }
    if (type == 'area') areaLinks.add(link);
  }

  void createLink(String name, String type) {
    if (userId == null) return;
    final tagId = vaultHandEditedTagIdFor(name, type);
    final linkId = isOutcome
        ? todoTagIdFor(key.entityId, tagId)
        : captureTagIdFor(key.entityId, tagId);
    final clock = mintClock();
    if (!tagName.containsKey(tagId)) {
      addField(tagsCollection, tagId, 'name', name, clock);
      addField(tagsCollection, tagId, 'type', type, clock);
      addField(tagsCollection, tagId, 'user_id', userId, clock);
    }
    addField(junctionCollection, linkId, ownerField, key.entityId, clock);
    addField(junctionCollection, linkId, 'tag_id', tagId, clock);
    addField(junctionCollection, linkId, 'user_id', userId, clock);
  }

  // The Labels: a name the page adds is a link to create, a name the page
  // drops is a link to delete.
  final shownLabelNames = shownLabels.toSet();
  for (final link in labelLinks) {
    if (shownLabelNames.contains(link.name)) continue;
    addTombstone(junctionCollection, link.entityId, mintClock());
  }
  for (final name in shownLabelNames) {
    if (labelLinks.any((link) => link.name == name)) continue;
    createLink(name, labelTagType);
  }

  // The Area: the page shows one name, so the entity has one area link. More
  // than one area link is a state the page cannot describe, and which one the
  // person meant is not knowable — so those are left alone.
  if (areaLinks.length > 1) {
    // left alone
  } else if (areaLinks.length == 1) {
    final link = areaLinks.single;
    if (shownArea != link.name) {
      addTombstone(junctionCollection, link.entityId, mintClock());
      if (shownArea != null) createLink(shownArea, 'area');
    }
  } else if (shownArea != null) {
    createLink(shownArea, 'area');
  }

  return [
    for (final ref in fields.keys.toList()..sort())
      Change(
        collection: ref.substring(0, ref.indexOf('/')),
        entityId: ref.substring(ref.indexOf('/') + 1),
        fields: fields[ref]!,
      ),
    for (final ref in tombstones.keys.toList()..sort())
      Change(
        collection: ref.substring(0, ref.indexOf('/')),
        entityId: ref.substring(ref.indexOf('/') + 1),
        tombstone: tombstones[ref],
      ),
  ];
}
