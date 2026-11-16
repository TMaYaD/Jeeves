@TestOn('!browser')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/folder/segment_format.dart';

Uint8List _fromHex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16),
    ]);

void main() {
  final vectors = jsonDecode(File('../spec/sync/folder_record_vectors.json').readAsStringSync())
      as Map<String, dynamic>;
  final envelope = _fromHex(vectors['envelope_hex'] as String);
  final record = _fromHex(vectors['record_hex'] as String);

  test('the frozen record is reproduced byte for byte and reads back', () {
    expect(encodeRecord(envelope), record);
    final read = readRecords(record);
    expect(read.single.envelope, envelope);
    expect(read.single.endOffset, record.length);
  });

  test('segment file names follow the frozen table', () {
    final names = (vectors['segment_file_names'] as Map<String, dynamic>).cast<String, String>();
    names.forEach((number, name) {
      expect(segmentFileName(int.parse(number)), name);
      expect(parseSegmentFileName(name), int.parse(number));
    });
    expect(parseSegmentFileName('000000.log'), isNull);
    expect(parseSegmentFileName('1.log'), isNull);
    expect(parseSegmentFileName('../000001.log'), isNull);
    expect(parseSegmentFileName('member.json'), isNull);
  });

  test('records after a partial one are not read past it', () {
    final two = Uint8List.fromList([...record, ...record]);
    expect(readRecords(two), hasLength(2));
    expect(readRecords(Uint8List.sublistView(two, 0, record.length + 5)), hasLength(1));
    expect(readRecords(Uint8List.sublistView(two, 0, record.length - 1)), isEmpty);
  });

  test('a corrupted checksum or an absurd length is "not yet arrived", never allocated for',
      () {
    final badChecksum = Uint8List.fromList(record)..[record.length - 1] ^= 1;
    expect(readRecords(badChecksum), isEmpty);
    final huge = Uint8List(64);
    ByteData.view(huge.buffer).setUint32(0, 0xffffffff, Endian.big);
    expect(readRecords(huge), isEmpty);
    final tiny = Uint8List(64);
    ByteData.view(tiny.buffer).setUint32(0, 3, Endian.big);
    expect(readRecords(tiny), isEmpty);
    expect(() => encodeRecord(Uint8List(maxEnvelopeBytes + 1)), throwsArgumentError);
  });

  test('the shortest envelope the reader accepts is the protocol minimum', () {
    expect(envelope.length, minimumEnvelopeBytes);
  });
}
