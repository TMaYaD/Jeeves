/// [Change] ↔ the signed op a folder record carries.
///
/// One op per change. When every clock in a change is one clock this member
/// stamped — an ordinary local write — it is a class-1 op with that clock as the op
/// clock. Anything else (snapshot entries, seeded floor clocks, forwarded changes)
/// is the class-4 shape: an op clock minted for the op, every field carrying its
/// own clock, a tombstone carrying `tombstone_hlc`. Nothing is re-stamped, so the
/// receiver's merge state holds the sender's clocks byte for byte.
library;

import '../envelope.dart';
import '../hlc.dart';
import '../host/change.dart';
import '../op_payload.dart';

/// The payload and op class for [change], or null when it carries no clock at all.
({OpPayload payload, int opClass})? payloadForChange(
  Change change, {
  required String memberIdHex,
  required Hlc Function() mintClock,
}) {
  final clocks = <Hlc>{
    for (final field in change.fields.values) field.hlc,
    if (change.tombstone != null) change.tombstone!,
  };
  if (clocks.isEmpty) return null;
  if (clocks.length == 1 && clocks.single.memberIdHex == memberIdHex) {
    return (
      payload: OpPayload(
        collection: change.collection,
        entityId: change.entityId,
        hlc: clocks.single,
        fields: {
          for (final entry in change.fields.entries) entry.key: FieldWrite(entry.value.value),
        },
        tombstone: change.tombstone != null,
      ),
      opClass: opClassContent,
    );
  }
  return (
    payload: OpPayload(
      collection: change.collection,
      entityId: change.entityId,
      hlc: mintClock(),
      fields: {
        for (final entry in change.fields.entries)
          entry.key: FieldWrite(entry.value.value, hlc: entry.value.hlc),
      },
      tombstone: change.tombstone != null,
      tombstoneHlc: change.tombstone,
    ),
    opClass: opClassCompaction,
  );
}
