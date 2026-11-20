/// The unit the sync host and its plugins exchange: one field-grain change.
///
/// Transport-neutral on purpose — nothing here names an op, an envelope, a
/// Workspace or a medium. A plugin turns its own wire format into these and back.
library;

import '../hlc.dart';

/// A clock in merge state that no op ever carried, and the entity it belongs
/// to.
///
/// The op-log bridge hands these back to the sync host when it will never
/// author them, so the host can re-stamp them under the device node id.
typedef UnauthoredClock = ({String collection, String entityId, Hlc clock});

/// A field's value together with the clock that orders it.
class ClockedValue {
  const ClockedValue(this.value, this.hlc);

  factory ClockedValue.fromJson(Map<String, Object?> json) =>
      ClockedValue(json['value'], Hlc.fromJson(json['hlc']));

  final Object? value;
  final Hlc hlc;

  Map<String, Object?> toJson() => {'value': value, 'hlc': hlc.toJson()};

  @override
  bool operator ==(Object other) =>
      other is ClockedValue && other.value == value && other.hlc == hlc;

  @override
  int get hashCode => Object.hash(value, hlc);
}

/// One field-grain change to one entity: a coalesced write with clocks, and/or a
/// deletion. A deletion is a clocked value ([tombstone]), never absence.
class Change {
  const Change({
    required this.collection,
    required this.entityId,
    this.fields = const {},
    this.tombstone,
  });

  factory Change.fromJson(Map<String, Object?> json) {
    final rawFields = (json['fields'] as Map<String, Object?>?) ?? const {};
    final rawTombstone = json['tombstone'];
    return Change(
      collection: json['collection']! as String,
      entityId: json['entity_id']! as String,
      fields: {
        for (final entry in rawFields.entries)
          entry.key:
              ClockedValue.fromJson((entry.value! as Map).cast<String, Object?>()),
      },
      tombstone: rawTombstone == null ? null : Hlc.fromJson(rawTombstone),
    );
  }

  final String collection;
  final String entityId;

  /// field → (value, clock).
  final Map<String, ClockedValue> fields;

  /// The clock the entity was deleted at, or null.
  final Hlc? tombstone;

  Map<String, Object?> toJson() => {
        'collection': collection,
        'entity_id': entityId,
        'fields': {
          for (final entry in fields.entries) entry.key: entry.value.toJson(),
        },
        'tombstone': tombstone?.toJson(),
      };

  /// The highest clock this change carries, or null for an empty change.
  Hlc? get highestClock {
    Hlc? highest = tombstone;
    for (final field in fields.values) {
      if (highest == null || field.hlc > highest) highest = field.hlc;
    }
    return highest;
  }

  @override
  String toString() => tombstone != null
      ? 'Change($collection/$entityId, tombstone, $fields)'
      : 'Change($collection/$entityId, $fields)';
}

/// A [Change] with its place in the host's durable change sequence.
class SequencedChange {
  const SequencedChange(this.sequence, this.change);

  final int sequence;
  final Change change;
}

/// What a plugin reports about itself. The two transport-neutral fields the
/// existing sync-health surface already has; a plugin that needs more extends it.
class PluginHealth {
  const PluginHealth({this.pendingChangeCount = 0, this.lastSyncedAt});

  final int pendingChangeCount;
  final DateTime? lastSyncedAt;
}
