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
///   "tombstone": true?,
///   "tombstone_hlc": [wall_ms, counter, "<hex32>"]?
/// }
/// ```
///
/// A field's `hlc` is optional and defaults to the op-level one. Only
/// compaction ops (#555) populate it per field, re-asserting the original
/// authors' clocks — which is why the reducer's sanity guards are scoped to the
/// op-level HLC and never to per-field HLCs (review F15).
///
/// `tombstone_hlc` is the same idea one level up, and [guardOpClassShape] fences
/// it to class 4: a compacted tombstone has to be re-asserted at its *original*
/// clock, because one re-stamped with the compactor's newer clock would bury a
/// resurrection the original could never have buried. Outside class 4 the field is
/// refused rather than ignored, so the format stays unambiguous.
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
    this.tombstoneHlc,
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

    final rawTombstoneHlc = raw['tombstone_hlc'];

    return OpPayload(
      collection: collection,
      entityId: entityId,
      hlc: Hlc.fromJson(raw['hlc']),
      fields: fields,
      tombstone: tombstone,
      tombstoneHlc:
          rawTombstoneHlc == null ? null : Hlc.fromJson(rawTombstoneHlc),
    );
  }

  final String collection;
  final String entityId;
  final Hlc hlc;
  final Map<String, FieldWrite> fields;
  final bool tombstone;

  /// The clock a *compacted* tombstone is re-asserted at — the original one, not
  /// the compactor's. Class 4 only; see [guardOpClassShape].
  final Hlc? tombstoneHlc;

  /// The HLC that decides this field: its own if it carries one, else the op's.
  Hlc clockFor(String field) => fields[field]?.hlc ?? hlc;

  /// The clock the tombstone applies at: its own if it carries one, else the op's.
  Hlc get effectiveTombstoneHlc => tombstoneHlc ?? hlc;

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
      if (tombstoneHlc != null) 'tombstone_hlc': tombstoneHlc!.toJson(),
    };
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
}

/// The class-4 shape rules, and the fence that keeps them out of every other class.
///
/// Applied between decode and reduce on receive, and again before anything is
/// signed at authoring — one function on both sides of that boundary, so an op no
/// receiver would apply can never reach an outbox.
///
/// The server never runs this on a POST: a class-4 body is ciphertext once the
/// Workspace is keyed, so the rule is codec parity and vector surface rather than a
/// route gate. That is not a weakening — every *receiver* enforces it, which is
/// where a payload's semantics have always been decided.
void guardOpClassShape(OpPayload payload, {required int opClass}) {
  if (opClass != opClassCompaction) {
    if (payload.tombstoneHlc != null) {
      throw SyncRejection(
        SyncRejectionReason.tombstoneHlcOutsideCompaction,
        'op_class $opClass carries tombstone_hlc, which is class-4 only',
      );
    }
    return;
  }
  for (final entry in payload.fields.entries) {
    if (entry.value.hlc == null) {
      throw SyncRejection(
        SyncRejectionReason.compactionFieldWithoutHlc,
        'compaction field "${entry.key}" carries no hlc of its own',
      );
    }
  }
  if (payload.tombstone && payload.tombstoneHlc == null) {
    throw const SyncRejection(
      SyncRejectionReason.compactionTombstoneWithoutHlc,
      'a compacted tombstone must be re-asserted at its original clock',
    );
  }
}
