/// The on-disk framing of an op-log folder segment.
///
/// An envelope is not self-delimiting — its length comes from the transport — so a
/// segment frames each one:
///
/// ```
/// record = u32 big-endian envelope length ‖ envelope ‖ 4-byte checksum
/// ```
///
/// The checksum is the first four bytes of SHA-256 over the length prefix and the
/// envelope. A segment has no file header; the format version lives in
/// `folder.json`.
///
/// A segment is read from files a file syncer, another app or a person can have
/// touched, so nothing here trusts a length before checking it against
/// [maxEnvelopeBytes], and nothing allocates from one.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../envelope.dart';

const int recordLengthPrefixBytes = 4;
const int recordChecksumBytes = 4;

/// The largest envelope a reader will accept. Bodies have no protocol cap, but a
/// record that claims more than this is treated as not yet arrived rather than
/// allocated for.
const int maxEnvelopeBytes = 8 * 1024 * 1024;

/// One segment is rolled once it reaches this size.
const int segmentRollBytes = 1024 * 1024;

/// One segment is rolled once its first record is this old.
const Duration segmentRollAge = Duration(hours: 24);

/// First segment number; segments are `NNNNNN.log`.
const int firstSegmentNumber = 1;

const int _maxSegmentNumber = 999999;

String segmentFileName(int number) {
  if (number < firstSegmentNumber || number > _maxSegmentNumber) {
    throw RangeError.range(number, firstSegmentNumber, _maxSegmentNumber, 'number');
  }
  return '${number.toString().padLeft(6, '0')}.log';
}

final RegExp _segmentNamePattern = RegExp(r'^([0-9]{6})\.log$');

/// The number a segment file name carries, or null for any other name.
int? parseSegmentFileName(String name) {
  final match = _segmentNamePattern.firstMatch(name);
  if (match == null) return null;
  final number = int.parse(match.group(1)!);
  return number < firstSegmentNumber ? null : number;
}

Uint8List _checksum(Uint8List prefix, Uint8List envelope) {
  final builder = BytesBuilder(copy: false)
    ..add(prefix)
    ..add(envelope);
  return Uint8List.fromList(
    crypto.sha256.convert(builder.toBytes()).bytes.sublist(0, recordChecksumBytes),
  );
}

/// The framed record for [envelope].
Uint8List encodeRecord(Uint8List envelope) {
  if (envelope.length > maxEnvelopeBytes) {
    throw ArgumentError.value(envelope.length, 'envelope', 'exceeds $maxEnvelopeBytes bytes');
  }
  final prefix = Uint8List(recordLengthPrefixBytes);
  ByteData.view(prefix.buffer).setUint32(0, envelope.length, Endian.big);
  final record = BytesBuilder(copy: false)
    ..add(prefix)
    ..add(envelope)
    ..add(_checksum(prefix, envelope));
  return record.toBytes();
}

/// Bytes a record of an envelope this long occupies on disk.
int recordLengthOf(int envelopeLengthBytes) =>
    recordLengthPrefixBytes + envelopeLengthBytes + recordChecksumBytes;

/// One complete record read from a segment.
class SegmentRecord {
  const SegmentRecord({required this.envelope, required this.endOffset});

  final Uint8List envelope;

  /// Byte offset just past this record's checksum.
  final int endOffset;
}

/// Every complete, checksummed record in [bytes], which begins at segment offset
/// [startOffset]. Reading stops — with no error — at the first byte run that is
/// not a whole record: it may be a record the syncer has not finished delivering.
List<SegmentRecord> readRecords(Uint8List bytes, {int startOffset = 0}) {
  final records = <SegmentRecord>[];
  var position = 0;
  while (position + recordLengthPrefixBytes <= bytes.length) {
    final prefix = Uint8List.sublistView(bytes, position, position + recordLengthPrefixBytes);
    final length = ByteData.sublistView(prefix).getUint32(0, Endian.big);
    if (length < minimumEnvelopeBytes || length > maxEnvelopeBytes) break;
    final end = position + recordLengthOf(length);
    if (end > bytes.length) break;
    final envelope =
        Uint8List.sublistView(bytes, position + recordLengthPrefixBytes, end - recordChecksumBytes);
    final stored = Uint8List.sublistView(bytes, end - recordChecksumBytes, end);
    if (!sameBytes(stored, _checksum(prefix, envelope))) break;
    records.add(SegmentRecord(
      envelope: Uint8List.fromList(envelope),
      endOffset: startOffset + end,
    ));
    position = end;
  }
  return records;
}
