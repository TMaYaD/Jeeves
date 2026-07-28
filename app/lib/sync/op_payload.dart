/// The `plaintext_v1` op payload format.
///
/// Mirror of `backend/app/sync/op_payload.py`, field for field.
///
/// ```json
/// {
///   "collection": "user_preferences",
///   "id": "<entity uuid>",
///   "fields": {"<field>": {"v": <json>, "hlc": [wall_ms, counter, "<hex32>"]?}},
///   "hlc": [wall_ms, counter, "<hex32>"],
///   "tombstone": true?
/// }
/// ```
///
/// A field's `hlc` is optional and defaults to the op-level one. Only
/// compaction ops (#555) populate it per field, re-asserting the original
/// authors' clocks — which is why the reducer's sanity guards are scoped to the
/// op-level HLC and never to per-field HLCs (review F15).
///
/// There is no canonical-JSON requirement: the signed artifact is the
/// serialized body bytes, and receivers parse them rather than re-serializing
/// to verify.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart' show DeepCollectionEquality;

import 'envelope.dart';
import 'hlc.dart';

/// Structural equality over decoded JSON values, which are arbitrarily nested
/// lists and maps — so `==` on [FieldWrite.value] has to recurse rather than
/// compare identities.
const DeepCollectionEquality _valueEquality = DeepCollectionEquality();

/// One field's new value, optionally carrying its own (older) HLC.
class FieldWrite {
  const FieldWrite(this.value, {this.hlc});

  final Object? value;
  final Hlc? hlc;

  @override
  bool operator ==(Object other) =>
      other is FieldWrite &&
      _valueEquality.equals(other.value, value) &&
      other.hlc == hlc;

  @override
  int get hashCode => Object.hash(_valueEquality.hash(value), hlc);
}

class OpPayload {
  const OpPayload({
    required this.collection,
    required this.entityId,
    required this.hlc,
    this.fields = const {},
    this.tombstone = false,
  });

  factory OpPayload.decode(Uint8List payload) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(payload));
    } on FormatException catch (error) {
      throw SyncRejection(
        SyncRejectionReason.malformedPayload,
        'payload is not UTF-8 JSON: $error',
      );
    }
    if (raw is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'payload must be a JSON object',
      );
    }

    final collection = raw['collection'];
    if (collection is! String || collection.isEmpty) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'collection must be a non-empty string',
      );
    }
    final entityId = raw['id'];
    // Same shape the Python codec requires, and the same one `uuidToBytes`
    // requires of the header ids: a canonical lowercase UUID and nothing else.
    // Accepting a spelling the other codec rejects would mean one device
    // applying an op its peer quarantines.
    if (entityId is! String || !isCanonicalUuid(entityId)) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'id must be a canonical lowercase UUID string',
      );
    }

    final rawFields = raw['fields'] ?? <String, dynamic>{};
    if (rawFields is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'fields must be an object',
      );
    }
    final fields = <String, FieldWrite>{};
    rawFields.forEach((name, entry) {
      if (entry is! Map<String, dynamic> || !entry.containsKey('v')) {
        throw SyncRejection(
          SyncRejectionReason.malformedPayload,
          'field "$name" must be an object with "v"',
        );
      }
      fields[name] = FieldWrite(
        entry['v'],
        hlc: entry.containsKey('hlc') ? Hlc.fromJson(entry['hlc']) : null,
      );
    });

    final tombstone = raw['tombstone'] ?? false;
    if (tombstone is! bool) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'tombstone must be a boolean',
      );
    }

    return OpPayload(
      collection: collection,
      entityId: entityId,
      hlc: Hlc.fromJson(raw['hlc']),
      fields: fields,
      tombstone: tombstone,
    );
  }

  final String collection;
  final String entityId;
  final Hlc hlc;
  final Map<String, FieldWrite> fields;
  final bool tombstone;

  /// The HLC that decides this field: its own if it carries one, else the op's.
  Hlc clockFor(String field) => fields[field]?.hlc ?? hlc;

  Map<String, Object?> toJson() {
    final fieldsJson = <String, Object?>{};
    fields.forEach((name, write) {
      fieldsJson[name] = {
        'v': write.value,
        if (write.hlc != null) 'hlc': write.hlc!.toJson(),
      };
    });
    return {
      'collection': collection,
      'id': entityId,
      'fields': fieldsJson,
      'hlc': hlc.toJson(),
      if (tombstone) 'tombstone': true,
    };
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
}
