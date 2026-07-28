/// The Dart codec against the frozen golden vectors.
///
/// `backend/tests/sync/test_envelope_vectors.py` runs the same assertions
/// against the same file. Two independent implementations agreeing
/// byte-for-byte with a committed artifact is what makes the in-process fake
/// server in `harness/` trustworthy as a stand-in for the real one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/op_payload.dart';

import 'vectors.dart';

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}

String _toHex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

OpHeader _headerFromJson(Map<String, dynamic> raw) => OpHeader(
      suite: raw['suite'] as int,
      opClass: raw['op_class'] as int,
      workspaceId: raw['workspace_id'] as String,
      keyEpoch: raw['key_epoch'] as int,
      opId: raw['op_id'] as String,
      authorMemberId: raw['author_member_id'] as String,
      authorKeyId: _fromHex(raw['author_key_id_hex'] as String),
      authorSeq: raw['author_seq'] as int,
      prevAuthorHash: _fromHex(raw['prev_author_hash_hex'] as String),
      observedHead: _fromHex(raw['observed_head_hex'] as String),
      nonce: _fromHex(raw['nonce_hex'] as String),
    );

/// The receiving client's fail-closed pipeline, in the same normative order
/// `SyncClient` uses and the Python suite mirrors.
Future<OpPayload> _receive(
  Uint8List envelope,
  String expectedWorkspaceId,
  Uint8List signPk,
) async {
  final parts = splitEnvelope(envelope);
  final header = OpHeader.parse(parts.header);
  header.checkServed();
  if (header.workspaceId != expectedWorkspaceId) {
    throw const SyncRejection(
      SyncRejectionReason.workspaceMismatch,
      'header workspace is not the pulled workspace',
    );
  }
  await verifyEnvelope(envelope, signPk);
  return OpPayload.decode(parseBody(parts.body));
}

void main() {
  final document = envelopeVectors();
  final protocol = document['protocol'] as Map<String, dynamic>;
  final identities = document['identities'] as Map<String, dynamic>;
  final keysByLabel = {
    for (final entry in identities['keys'] as List<dynamic>)
      (entry as Map<String, dynamic>)['label'] as String: entry,
  };

  Future<EnvelopeSigner> signerFor(String label) =>
      EnvelopeSigner.fromSeed(_fromHex(keysByLabel[label]!['seed_hex'] as String));

  group('protocol constants', () {
    test('match the frozen file', () {
      expect(protocol['header_length_bytes'], headerLengthBytes);
      expect(protocol['signature_length_bytes'], signatureLengthBytes);
      expect(protocol['envelope_overhead_bytes'], envelopeOverheadBytes);
      expect(protocol['signing_domain'], signingDomainOpV1);
      expect((protocol['suites'] as Map)['plaintext_v1'], suitePlaintextV1);
      expect((protocol['suites'] as Map)['aead_v1_reserved'], suiteAeadV1);
      expect(protocol['served_suites'], servedSuites.toList()..sort());
      expect(protocol['served_op_classes'], servedOpClasses.toList()..sort());
      expect(protocol['known_op_classes'], knownOpClasses.toList()..sort());
      expect(protocol['body_size_classes_bytes'], bodySizeClassesBytes);
      expect(protocol['body_oversize_multiple_bytes'], bodyOversizeMultipleBytes);
      expect(protocol['payload_length_prefix_bytes'], payloadLengthPrefixBytes);
      expect(protocol['workspace_namespace_uuid'], jeevesWorkspaceNamespace);
    });

    test('header field layout is contiguous and sums to the header length', () {
      final layout = vectorList(protocol, 'header_field_layout');
      var runningOffset = 0;
      for (final field in layout) {
        expect(field['offset'], runningOffset, reason: field['name'] as String);
        runningOffset += field['length_bytes'] as int;
      }
      expect(runningOffset, headerLengthBytes);
    });
  });

  group('derived identities', () {
    test('the implicit workspace id is a uuid5 of the user id', () {
      expect(
        implicitWorkspaceId(identities['user_id'] as String),
        identities['workspace_id'],
      );
      expect(
        implicitWorkspaceId(identities['other_user_id'] as String),
        identities['other_workspace_id'],
      );
    });

    test('the preference entity id is a uuid5 of the key in the workspace', () {
      expect(
        preferenceEntityId(
          identities['workspace_id'] as String,
          identities['preference_key'] as String,
        ),
        identities['preference_entity_id'],
      );
    });

    test('key ids are derived from the public keys', () async {
      for (final entry in identities['keys'] as List<dynamic>) {
        final key = entry as Map<String, dynamic>;
        final signer = await EnvelopeSigner.fromSeed(_fromHex(key['seed_hex'] as String));
        expect(_toHex(signer.signPublicKey), key['sign_pk_hex']);
        expect(_toHex(signer.keyId), key['key_id_hex']);
      }
    });
  });

  group('header vectors', () {
    for (final vector in vectorList(document, 'header_vectors')) {
      test('${vector['name']} serializes and round-trips', () {
        final header = _headerFromJson(vector['header'] as Map<String, dynamic>);
        final serialized = header.serialize();
        expect(_toHex(serialized), vector['header_hex']);
        expect(serialized.length, headerLengthBytes);
        expect(_toHex(OpHeader.parse(serialized).serialize()), vector['header_hex']);
      });
    }
  });

  group('positive vectors', () {
    for (final vector in vectorList(document, 'vectors')) {
      test('${vector['name']} is byte-identical', () async {
        final header = _headerFromJson(vector['header'] as Map<String, dynamic>);
        final payload =
            Uint8List.fromList(utf8.encode(vector['payload_json'] as String));

        expect(_toHex(header.serialize()), vector['header_hex']);
        expect(payload.length, vector['payload_length_bytes']);

        final body = frameBody(payload);
        expect(body.length, vector['body_length_bytes']);
        expect(_toHex(body), vector['body_hex']);

        final signer = await signerFor(vector['key'] as String);
        final envelope = await signer.buildEnvelope(header, body);
        expect(_toHex(envelope), vector['envelope_hex']);
        expect(
          _toHex(Uint8List.fromList(
            envelope.sublist(envelope.length - signatureLengthBytes),
          )),
          vector['signature_hex'],
        );
        expect(_toHex(envelopeHash(envelope)), vector['envelope_sha256_hex']);
      });

      test('${vector['name']} round-trips through the receive pipeline', () async {
        final envelope = _fromHex(vector['envelope_hex'] as String);
        final parts = splitEnvelope(envelope);
        expect(
          _toHex(OpHeader.parse(parts.header).serialize()),
          vector['header_hex'],
        );
        expect(utf8.decode(parseBody(parts.body)), vector['payload_json']);

        final key = keysByLabel[vector['key'] as String]!;
        final payload = await _receive(
          envelope,
          (vector['header'] as Map<String, dynamic>)['workspace_id'] as String,
          _fromHex(key['sign_pk_hex'] as String),
        );
        // Re-encoding is not part of verification (the signed artifact is the
        // body bytes), but a decode that loses information would break merges.
        expect(utf8.decode(payload.encode()), vector['payload_json']);
      });
    }
  });

  group('negative vectors', () {
    for (final vector in vectorList(document, 'negative_vectors')) {
      test('${vector['name']} fails closed as ${vector['reason']}', () async {
        final key = keysByLabel[vector['key'] as String]!;
        SyncRejection? rejection;
        try {
          await _receive(
            _fromHex(vector['envelope_hex'] as String),
            vector['expected_workspace_id'] as String,
            _fromHex(key['sign_pk_hex'] as String),
          );
        } on SyncRejection catch (thrown) {
          rejection = thrown;
        }
        expect(rejection, isNotNull, reason: 'vector was accepted');
        expect(rejection!.reason.code, vector['reason']);
      });
    }

    test('the non-zero padding byte sits at the first padding position', () {
      final vector = vectorList(document, 'negative_vectors')
          .firstWhere((entry) => entry['name'] == 'non_zero_padding');
      final body = splitEnvelope(_fromHex(vector['envelope_hex'] as String)).body;
      final payloadLength = ByteData.view(body.buffer, body.offsetInBytes)
          .getUint32(0, Endian.big);
      final firstPaddingOffset = payloadLengthPrefixBytes + payloadLength;
      expect(body[firstPaddingOffset], isNot(0));
      expect(
        body.sublist(firstPaddingOffset + 1).every((byte) => byte == 0),
        isTrue,
      );
    });
  });

  group('body framing', () {
    test('size classes and the oversize multiple', () {
      expect(paddedBodyLength(1), 256);
      expect(paddedBodyLength(256), 256);
      expect(paddedBodyLength(257), 1024);
      expect(paddedBodyLength(16384), 16384);
      expect(paddedBodyLength(16385), 32768);
      expect(paddedBodyLength(32768), 32768);
      expect(paddedBodyLength(32769), 49152);

      expect(isLegalBodyLength(256), isTrue);
      expect(isLegalBodyLength(32768), isTrue);
      expect(isLegalBodyLength(49152), isTrue);
      expect(isLegalBodyLength(0), isFalse);
      expect(isLegalBodyLength(300), isFalse);
      expect(isLegalBodyLength(16385), isFalse);
    });

    test('round-trips across every size-class boundary', () {
      for (final payloadLength in [0, 1, 251, 252, 253, 1019, 1020, 16379, 16380, 16381]) {
        final payload = Uint8List.fromList(List.filled(payloadLength, 0x7A));
        final body = frameBody(payload);
        expect(isLegalBodyLength(body.length), isTrue);
        expect(parseBody(body), payload);
      }
    });
  });

  group('member id hex', () {
    test('is rejected unless it is 32 lowercase hex characters', () {
      expect(() => Hlc(1, 0, 'ABCDEF01234567890123456789ABCDEF'), throwsRejection());
      expect(() => Hlc(1, 0, 'not-hex'), throwsRejection());
      expect(() => Hlc(1, 0, '0123456789abcdef0123456789abcde'), throwsRejection());
      expect(Hlc(1, 0, '0123456789abcdef0123456789abcdef').memberIdHex,
          '0123456789abcdef0123456789abcdef');
    });

    test('memberIdToHex strips dashes and lowercases a member UUID', () {
      expect(
        memberIdToHex('6C88DFA7-37AF-53E5-83D1-93346DF45BD4'),
        '6c88dfa737af53e583d193346df45bd4',
      );
    });
  });
}

Matcher throwsRejection([SyncRejectionReason? reason]) => throwsA(
      predicate<Object>(
        (error) =>
            error is SyncRejection && (reason == null || error.reason == reason),
        'a SyncRejection${reason == null ? '' : ' (${reason.code})'}',
      ),
    );
