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
import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';

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

/// The control half of the receive pipeline, in D6's normative order.
///
/// Steps 1-5 of the six: the chain check needs state a vector cannot carry, so
/// it is pinned by the harness tests instead. The envelope-signature check runs
/// *here*, against the certificate's key — for a MemberRegister the author is
/// by definition not yet in the directory, which is exactly why it defers into
/// this path.
/// The directory lookup, standing in for a chain-gated one.
///
/// A real receiver learns a member's key from that member's own Root-signed
/// registration; here the spec identities are the directory, which is enough to
/// pin *which* key each control type is verified against.
Uint8List _specSignPk(Map<String, dynamic> identities, String memberId) {
  for (final entry in identities['keys'] as List<dynamic>) {
    final key = entry as Map<String, dynamic>;
    if (key['member_id'] == memberId) return _fromHex(key['sign_pk_hex'] as String);
  }
  throw SyncRejection(
    SyncRejectionReason.memberNotChainedToRoot,
    'no spec key for member $memberId',
  );
}

/// The load-bearing step: the certificate's *own* key must have signed this.
///
/// A genuine certificate is public the moment it is in the log. Without this
/// check anyone holding a copy could wrap it around self-signed envelopes and
/// manufacture forks in the victim's chain.
Future<void> _bindRegistration(
  RegistrationCertificate certificate,
  Uint8List envelope,
  OpHeader header,
) async {
  if (certificate.memberId != header.authorMemberId) {
    throw const SyncRejection(
      SyncRejectionReason.badRootSignature,
      'certificate names another member',
    );
  }
  await verifyEnvelope(envelope, certificate.signPk);
  if (_toHex(certificate.signKeyId) != _toHex(header.authorKeyId)) {
    throw const SyncRejection(
      SyncRejectionReason.badRootSignature,
      'certificate key id is not the one the header names',
    );
  }
}

/// The control half of the receive pipeline, dispatched per type.
///
/// Returns the parsed certificate: a [RegistrationCertificate] for a
/// `member_register`, a [GenesisCertificate] for a `workspace_genesis` (which
/// *embeds* one), a [GrantCertificate], or a [RevokeCertificate].
///
/// Everything needing receiver **state** is deliberately absent, because a vector
/// cannot carry it: the position rule, the chain rule against what has been
/// applied, an unmaterialised grantee, a Service grant into the preferences
/// Workspace, and the *revoke* half of the owner ceiling — that last one because
/// the frozen revoke certificate names a `grant_id`, so the target's role is state
/// rather than bytes. Those are pinned by the route and harness tests.
Future<Object> _receiveControl(
  Uint8List envelope,
  Uint8List rootPk,
  Map<String, dynamic> identities,
) async {
  final parts = splitEnvelope(envelope);
  final header = OpHeader.parse(parts.header);
  header.checkServed();
  expect(header.opClass, opClassControl);

  final payload = ControlPayload.decode(parseBody(parts.body));
  payload.requireServedType();
  payload.requireChainLinkShape();

  switch (payload.controlType) {
    case controlTypeWorkspaceGenesis:
      await verifyGenesisCertificate(payload.certBytes, payload.rootSig, rootPk);
      final genesis = payload.genesisCertificate();
      if (!sameBytes(genesis.rootPk, rootPk)) {
        // The Root inside the signed genesis must be the Root this receiver
        // pinned: that cross-check is why it is in there at all.
        throw const SyncRejection(
          SyncRejectionReason.badRootSignature,
          'the genesis names a different Root',
        );
      }
      // The founder's registration is *inside* the genesis, so the binding check
      // runs against it while the genesis certificate stays what was signed.
      await _bindRegistration(genesis.asRegistration(), envelope, header);
      return genesis;

    case controlTypeMemberRegister:
      await verifyRegistrationCertificate(payload.certBytes, payload.rootSig, rootPk);
      final certificate = payload.certificate();
      await _bindRegistration(certificate, envelope, header);
      return certificate;

    default:
      // Grant and Revoke: the authority is Root or an owning Member, and *which*
      // key verifies the certificate is decided by the payload's own `authority`
      // field and nothing else. The envelope itself is verified against the
      // author's directory key, as any non-registering op is.
      final authorityPk = payload.authority == granterRoot
          ? rootPk
          : _specSignPk(identities, payload.authority);
      await verifyEnvelope(envelope, _specSignPk(identities, header.authorMemberId));
      if (payload.controlType == controlTypeGrant) {
        await verifyGrantCertificate(payload.certBytes, payload.signature, authorityPk);
        final grant = payload.grantCertificate();
        if (grant.granter != payload.authority) {
          // The signed certificate names its own granter; the payload field only
          // says which key to check it against.
          throw const SyncRejection(
            SyncRejectionReason.badGrantSignature,
            'the certificate and the payload disagree about the granter',
          );
        }
        return grant;
      }
      await verifyRevokeCertificate(payload.certBytes, payload.signature, authorityPk);
      final revoke = payload.revokeCertificate();
      if (revoke.revoker != payload.authority) {
        throw const SyncRejection(
          SyncRejectionReason.badRevokeSignature,
          'the certificate and the payload disagree about the revoker',
        );
      }
      return revoke;
  }
}

/// The bytes a decoded control certificate re-encodes to, whichever type it is.
Uint8List _certBytesOf(Object certificate) => switch (certificate) {
      GenesisCertificate() => certificate.encode(),
      RegistrationCertificate() => certificate.encode(),
      GrantCertificate() => certificate.encode(),
      RevokeCertificate() => certificate.encode(),
      _ => throw ArgumentError('not a control certificate: $certificate'),
    };


void main() {
  final document = envelopeVectors();
  final protocol = document['protocol'] as Map<String, dynamic>;
  final identities = document['identities'] as Map<String, dynamic>;
  final keysByLabel = {
    for (final entry in identities['keys'] as List<dynamic>)
      (entry as Map<String, dynamic>)['label'] as String: entry,
  };
  final rootPk =
      _fromHex((identities['root'] as Map<String, dynamic>)['root_pk_hex'] as String);

  Future<EnvelopeSigner> signerFor(String label) =>
      EnvelopeSigner.fromSeed(_fromHex(keysByLabel[label]!['seed_hex'] as String));

  Future<RootAuthority> specRoot() => RootAuthority.fromSecretKey(
        _fromHex((identities['root'] as Map<String, dynamic>)['seed_hex'] as String),
      );

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
        defaultWorkspaceId(identities['user_id'] as String),
        identities['workspace_id'],
      );
      expect(
        defaultWorkspaceId(identities['other_user_id'] as String),
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

  group('author_seq representability', () {
    /// The 158 header bytes with `author_seq` set to [high]:[low], written
    /// directly because `OpHeader.serialize` refuses to emit a value it could
    /// not read back.
    Uint8List headerWithAuthorSeq(int high, int low) {
      final bytes = Uint8List(headerLengthBytes);
      final view = ByteData.view(bytes.buffer);
      bytes[1] = opClassContent;
      view.setUint32(62, high, Endian.big);
      view.setUint32(66, low, Endian.big);
      return bytes;
    }

    test('2^53 - 1 is the largest header a client will read', () {
      expect(
        OpHeader.parse(headerWithAuthorSeq(0x001FFFFF, 0xFFFFFFFF)).authorSeq,
        maxRepresentableAuthorSeq,
      );
    });

    test('2^53 is refused rather than rounded', () {
      expect(
        () => OpHeader.parse(headerWithAuthorSeq(0x00200000, 0)),
        throwsRejection(SyncRejectionReason.unrepresentableAuthorSeq),
      );
    });
  });

  group('minimum envelope length', () {
    test('follows from the smallest body size class', () {
      expect(
        minimumEnvelopeBytes,
        headerLengthBytes + bodySizeClassesBytes.first + signatureLengthBytes,
      );
      // Strictly more than header + signature: a body is never empty.
      expect(minimumEnvelopeBytes, greaterThan(envelopeOverheadBytes));
    });
  });

  group('entity id', () {
    Uint8List payloadWithId(String id) => Uint8List.fromList(
          utf8.encode(jsonEncode({
            'collection': 'user_preferences',
            'id': id,
            'fields': <String, Object?>{},
            'hlc': [1, 0, '0123456789abcdef0123456789abcdef'],
          })),
        );

    test('is accepted only in canonical lowercase form', () {
      const canonical = '6c88dfa7-37af-53e5-83d1-93346df45bd4';
      expect(OpPayload.decode(payloadWithId(canonical)).entityId, canonical);

      // Each of these is something `uuid.UUID` would have swallowed on the
      // Python side. Both codecs now reject them, so neither can apply an op
      // the other quarantines.
      for (final spelling in [
        '6c88dfa737af53e583d193346df45bd4',
        '6C88DFA7-37AF-53E5-83D1-93346DF45BD4',
        '{6c88dfa7-37af-53e5-83d1-93346df45bd4}',
        'urn:uuid:6c88dfa7-37af-53e5-83d1-93346df45bd4',
        'not-a-uuid',
      ]) {
        expect(
          () => OpPayload.decode(payloadWithId(spelling)),
          throwsRejection(SyncRejectionReason.malformedPayload),
          reason: spelling,
        );
      }
    });
  });

  group('control plane', () {
    test('constants match the frozen file', () {
      final domains = protocol['signing_domains'] as Map<String, dynamic>;
      expect(domains['op_v1'], signingDomainOpV1);
      expect(domains['member_register_v1'], signingDomainMemberRegisterV1);
      expect(domains['workspace_genesis_v1'], signingDomainWorkspaceGenesisV1);
      expect(domains['grant_v1'], signingDomainGrantV1);
      expect(domains['revoke_v1'], signingDomainRevokeV1);
      expect(domains['auth_challenge_v1'], signingDomainAuthChallengeV1);
      expect(domains['escrow_v1'], signingDomainEscrowV1);
      // Seven distinct domains, or a signature made for one use would verify for
      // another (review F7). Grant and Revoke are separate for exactly that
      // reason: an unmaking must never be replayable as a making.
      expect(domains.values.toSet().length, domains.length);

      final control = protocol['control'] as Map<String, dynamic>;
      expect(control['member_register_type'], controlTypeMemberRegister);
      expect(control['workspace_genesis_type'], controlTypeWorkspaceGenesis);
      expect(control['grant_type'], controlTypeGrant);
      expect(control['revoke_type'], controlTypeRevoke);
      expect(control['served_control_types'], servedControlTypes.toList()..sort());
      expect(control['member_kind_device'], memberKindDevice);
      expect(control['member_kind_service'], memberKindService);
      expect(control['prev_control_hash_bytes'], prevControlHashBytes);
      expect(control['zero_prev_control_hash_hex'], _toHex(zeroPrevControlHash));
      expect(control['kex_public_key_bytes'], kexPublicKeyBytes);
      expect(control['granter_root'], granterRoot);
      expect(control['roles'], knownRoles);
      expect(control['role_op_class_matrix'], {
        for (final entry in roleOpClassMatrix.entries)
          '${entry.key}': entry.value.toList()..sort(),
      });
      // op_class 2 is served: this slice widened what a control op may *say*
      // rather than whether it is carried.
      expect(servedOpClasses, contains(opClassControl));
    });

    test('the compaction exemption is pinned before prune exists', () {
      // #555 must honour a rule the vectors already froze: compacting a control
      // op away would delete the evidence a Grant ever existed, and a prune op is
      // itself the attestation that history was removed.
      final control = protocol['control'] as Map<String, dynamic>;
      expect(control['compaction_exempt_op_classes'], compactionExemptOpClasses.toList()..sort());
      expect(isCompactionExempt(opClassControl), isTrue);
      expect(isCompactionExempt(opClassPrune), isTrue);
      expect(isCompactionExempt(opClassContent), isFalse);
      expect(isCompactionExempt(opClassCompaction), isFalse);
    });

    test('both implicit workspace ids match the frozen file', () {
      // Two derivation-addressed Workspaces per User, independent by
      // construction: neither id is computable from the other, which is what lets
      // a client that knows only one reach only one.
      expect(protocol['workspace_namespace_uuid'], jeevesWorkspaceNamespace);
      expect(
        protocol['user_preferences_workspace_namespace_uuid'],
        userPreferencesWorkspaceNamespace,
      );
      final userId = identities['user_id'] as String;
      expect(identities['workspace_id'], defaultWorkspaceId(userId));
      expect(
        identities['user_preferences_workspace_id'],
        userPreferencesWorkspaceId(userId),
      );
      expect(
        identities['workspace_id'],
        isNot(identities['user_preferences_workspace_id']),
      );
    });

    for (final vector in vectorList(document, 'control_vectors')) {
      test('${vector['name']} is byte-identical', () async {
        final header = _headerFromJson(vector['header'] as Map<String, dynamic>);
        final payload =
            Uint8List.fromList(utf8.encode(vector['payload_json'] as String));

        expect(header.opClass, opClassControl);
        expect(_toHex(header.serialize()), vector['header_hex']);
        expect(payload.length, vector['payload_length_bytes']);

        final body = frameBody(payload);
        expect(_toHex(body), vector['body_hex']);
        final signer = await signerFor(vector['key'] as String);
        final envelope = await signer.buildEnvelope(header, body);
        expect(_toHex(envelope), vector['envelope_hex']);
        expect(_toHex(envelopeHash(envelope)), vector['envelope_sha256_hex']);

        // The control chain link is over the payload bytes, never the envelope —
        // and the per-author link is over the envelope, never the payload. Two
        // different hashes over two different byte ranges, and a codec that
        // confused them would fail right here.
        expect(_toHex(controlPayloadHash(payload)), vector['payload_sha256_hex']);
        expect(
          _toHex(controlPayloadHash(payload)),
          isNot(vector['envelope_sha256_hex']),
        );
      });

      test('${vector['name']} round-trips through the receive pipeline',
          () async {
        final envelope = _fromHex(vector['envelope_hex'] as String);
        final certificate = await _receiveControl(envelope, rootPk, identities);

        // The signed artifact is the certificate's literal bytes; a lossy decode
        // would break every verifier.
        final certBytes = _certBytesOf(certificate);
        expect(utf8.decode(certBytes), vector['cert_json']);
        expect(_toHex(certBytes), vector['cert_hex']);

        final payload =
            ControlPayload.decode(parseBody(splitEnvelope(envelope).body));
        expect(payload.controlType, vector['control_type']);
        expect(_toHex(payload.prevControlHash), vector['prev_control_hash_hex']);
        expect(_toHex(payload.signature), vector['signature_hex']);
        expect(payload.authority, vector['authority']);
      });

      if (registeringControlTypes.contains(vector['control_type'])) {
        test('${vector['name']} carries its authors own keys', () async {
          // An author's first op must be the control op that registers it. #548's
          // rule was "a `member_register` is its author's op 1"; genesis
          // generalises it, because genesis *is* the founding Device's
          // registration (ADR-0031). Either way the certificate has to carry the
          // very key that signed the envelope, or the envelope could not be
          // verified at all.
          final decoded =
              await _receiveControl(_fromHex(vector['envelope_hex'] as String), rootPk, identities);
          final registration = decoded is GenesisCertificate
              ? decoded.asRegistration()
              : decoded as RegistrationCertificate;
          final key = keysByLabel[vector['key'] as String]!;
          expect(
            _headerFromJson(vector['header'] as Map<String, dynamic>).authorSeq,
            1,
          );
          expect(_toHex(registration.signPk), key['sign_pk_hex']);
          expect(_toHex(registration.kexPk), key['kex_pk_hex']);
          expect(registration.memberId, key['member_id']);
          expect(registration.memberKind, memberKindDevice);
        });
      }
    }

    test('the canonical control chain links payload hash to payload hash', () {
      // Genesis first, zero link, then every successor naming its predecessor.
      // The ops are authored by two devices under three different authorities,
      // and the link is the same hash-of-payload-bytes throughout.
      final chain = vectorList(document, 'control_vectors');
      expect(
        [for (final vector in chain) vector['control_type']],
        [
          controlTypeWorkspaceGenesis,
          controlTypeGrant,
          controlTypeMemberRegister,
          controlTypeGrant,
          controlTypeGrant,
          controlTypeRevoke,
        ],
      );
      expect(chain.first['prev_control_hash_hex'], _toHex(zeroPrevControlHash));
      for (var index = 1; index < chain.length; index++) {
        expect(
          chain[index]['prev_control_hash_hex'],
          chain[index - 1]['payload_sha256_hex'],
          reason: 'control op $index does not name its predecessor',
        );
      }
    });

    test('the canonical chain pins both authority shapes', () {
      final chain = vectorList(document, 'control_vectors');
      final grants = [
        for (final vector in chain)
          if (vector['control_type'] == controlTypeGrant)
            (
              vector: vector,
              cert: GrantCertificate.decode(_fromHex(vector['cert_hex'] as String)),
            ),
      ];
      final owners = grants.where((entry) => entry.cert.role == roleOwner);
      expect(owners, isNotEmpty, reason: 'the chain must exercise the Root-only mint');
      for (final entry in owners) {
        // The ceiling, in the vectors rather than only in the prose.
        expect(entry.vector['authority'], granterRoot);
      }

      final memberSigned =
          grants.where((entry) => entry.vector['authority'] != granterRoot).toList();
      expect(memberSigned.length, 1);
      final delegated = memberSigned.single;
      expect(delegated.cert.role, isNot(roleOwner));
      // Authority does not travel by courier: the envelope author, the payload's
      // authority and the certificate's granter are one member.
      expect(delegated.cert.granter, delegated.vector['authority']);
      expect(
        (delegated.vector['header'] as Map<String, dynamic>)['author_member_id'],
        delegated.cert.granter,
      );
      // A Grant carries no key material — the Grant/KeyWrap split (F19) — so its
      // grantee need not be anything this document holds a keypair for.
      expect(delegated.cert.memberId, identities['suggester_member_id']);
    });

    test('the canonical chain revokes by grant id', () {
      // Revocation is grant-granular: it names a Grant, never a member (F19).
      final chain = vectorList(document, 'control_vectors');
      final revokeVector =
          chain.firstWhere((vector) => vector['control_type'] == controlTypeRevoke);
      final revoke = RevokeCertificate.decode(_fromHex(revokeVector['cert_hex'] as String));
      final granted = {
        for (final vector in chain)
          if (vector['control_type'] == controlTypeGrant)
            GrantCertificate.decode(_fromHex(vector['cert_hex'] as String)).grantId,
      };
      expect(granted, contains(revoke.grantId));
      // Only Root revokes an owner; this one takes away a suggester, so it could
      // have been member-signed and is Root-signed here for the canonical path.
      expect(revoke.revoker, granterRoot);
    });

    for (final vector in vectorList(document, 'negative_control_vectors')) {
      test('${vector['name']} fails closed as ${vector['reason']}', () async {
        SyncRejection? rejection;
        try {
          await _receiveControl(
            _fromHex(vector['envelope_hex'] as String),
            rootPk,
            identities,
          );
        } on SyncRejection catch (thrown) {
          rejection = thrown;
        }
        expect(rejection, isNotNull, reason: 'vector was accepted');
        expect(rejection!.reason.code, vector['reason']);
      });
    }

    test('a certificate wrapped around another devices envelope is refused',
        () async {
      // The load-bearing binding step. A genuine certificate is public once it is
      // in the log; without this check anyone holding a copy could wrap it around
      // self-signed envelopes and fork the victim's chain.
      final genuine = vectorList(document, 'control_vectors').first;
      final payload =
          parseBody(splitEnvelope(_fromHex(genuine['envelope_hex'] as String)).body);
      final header = _headerFromJson(genuine['header'] as Map<String, dynamic>);
      final forger = await signerFor('device_b');
      final forged = await forger.buildEnvelope(header, frameBody(payload));

      expect(
        () => _receiveControl(forged, rootPk, identities),
        throwsRejection(SyncRejectionReason.badSignature),
      );
    });
  });


  group('escrow and challenge preimages', () {
    test('escrow constants match the frozen file', () {
      final escrow = protocol['escrow'] as Map<String, dynamic>;
      expect(escrow['blob_magic'], ascii.decode(escrowBlobMagic));
      expect(escrow['salt_bytes'], escrowSaltBytes);
      expect(escrow['nonce_bytes'], escrowNonceBytes);
      expect(escrow['secret_bytes'], escrowSecretBytes);
      expect(escrow['blob_header_bytes'], escrowBlobHeaderBytes);
      expect(escrow['blob_bytes'], escrowBlobBytes);
      expect(escrow['first_version'], firstEscrowVersion);
      expect(escrow['argon2id_floor'], {
        'memory_kib': argon2idFloorMemoryKib,
        'time_cost': argon2idFloorTimeCost,
        'parallelism': argon2idFloorParallelism,
      });
    });

    for (final vector in vectorList(document, 'escrow_vectors')) {
      test('${vector['name']} is byte-identical', () async {
        final workspaceId = vector['workspace_id'] as String;
        final blob = _fromHex(vector['blob_hex'] as String);
        final signingInput =
            escrowSigningInput(workspaceId, vector['version'] as int, blob);
        expect(_toHex(signingInput), vector['signing_input_hex']);
        // The slot is inside the signed bytes: workspace first, then version.
        expect(
          _toHex(signingInput).startsWith(
            _toHex(Uint8List.fromList(ascii.encode(signingDomainEscrowV1))) +
                _toHex(uuidToBytes(workspaceId)),
          ),
          isTrue,
        );

        final root = await specRoot();
        expect(
          _toHex(await root.signEscrow(workspaceId, vector['version'] as int, blob)),
          vector['root_sig_hex'],
        );
        await verifyEscrowRecordSignature(
          RecoveryEscrowRecord(
            version: vector['version'] as int,
            blob: blob,
            rootSig: _fromHex(vector['root_sig_hex'] as String),
            rootPk: rootPk,
          ),
          workspaceId,
          rootPk,
        );
      });
    }

    test('an escrow signature does not transfer between slots or versions',
        () async {
      final vectors = vectorList(document, 'escrow_vectors');
      final first = vectors.first;
      final second = vectors[1];
      expect(first['root_sig_hex'], isNot(second['root_sig_hex']));

      final blob = _fromHex(first['blob_hex'] as String);
      final signature = _fromHex(first['root_sig_hex'] as String);
      Future<void> expectRefused(String workspaceId, int version) async {
        await expectLater(
          verifyEscrowRecordSignature(
            RecoveryEscrowRecord(
              version: version,
              blob: blob,
              rootSig: signature,
              rootPk: rootPk,
            ),
            workspaceId,
            rootPk,
          ),
          throwsA(
            predicate<Object>(
              (error) =>
                  error is RecoveryEscrowException &&
                  error.failure == RecoveryEscrowFailure.rootMismatch &&
                  error.isAlarm,
              'an escrow root-mismatch alarm',
            ),
          ),
        );
      }

      await expectRefused(first['workspace_id'] as String, second['version'] as int);
      await expectRefused(
        identities['other_workspace_id'] as String,
        first['version'] as int,
      );
    });

    for (final vector in vectorList(document, 'member_challenge_vectors')) {
      test('${vector['name']} is byte-identical', () async {
        final memberId = vector['member_id'] as String;
        final nonce = _fromHex(vector['nonce_hex'] as String);
        final key = keysByLabel[vector['key'] as String]!;
        final identity = await MemberIdentity.generate(
          memberId: memberId,
          signSeed: _fromHex(key['seed_hex'] as String),
          kexSeed: _fromHex(key['seed_hex'] as String),
        );

        expect(
          _toHex(
            domainSeparated(
              signingDomainAuthChallengeV1,
              [uuidToBytes(memberId), nonce],
            ),
          ),
          vector['signing_input_hex'],
        );
        expect(
          _toHex(await identity.signTransportChallenge(nonce)),
          vector['signature_hex'],
        );

        // The member id is inside the preimage, so the same nonce under
        // another member's slot is a different signature.
        final otherMemberId = keysByLabel['device_b']!['member_id'] as String;
        expect(
          await verifyDomainSeparated(
            domainSeparated(
              signingDomainAuthChallengeV1,
              [uuidToBytes(otherMemberId), nonce],
            ),
            _fromHex(vector['signature_hex'] as String),
            _fromHex(key['sign_pk_hex'] as String),
          ),
          isFalse,
        );
      });
    }
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
