/// A bare author that mints real, correctly chained envelopes.
///
/// The twin of `backend/tests/sync/builders.py`'s `SpecDevice`: it exists for
/// the transport contract tests, which care about the header, the chain and the
/// dedupe key and not at all about what a device does with the result.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jeeves/sync/envelope.dart';
import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

class AuthorFixture {
  AuthorFixture._(this.memberId, this.signer);

  static Future<AuthorFixture> create({String? memberId, Uint8List? seed}) async {
    final signer = await EnvelopeSigner.fromSeed(
      seed ?? Uint8List.fromList(List<int>.generate(32, (index) => index + 1)),
    );
    return AuthorFixture._(memberId ?? _uuid.v4(), signer);
  }

  final String memberId;
  final EnvelopeSigner signer;

  int nextAuthorSeq = 1;
  Uint8List lastEnvelopeHash = Uint8List(prevAuthorHashBytes);

  Uint8List get signPk => signer.signPublicKey;

  Future<Uint8List> nextEnvelope(
    String workspaceId, {
    String? opId,
    int suite = suitePlaintextV1,
    int opClass = opClassContent,
    int keyEpoch = 0,
    String payloadJson = '{"collection":"test"}',
    bool advance = true,
  }) async {
    final header = OpHeader(
      suite: suite,
      opClass: opClass,
      workspaceId: workspaceId,
      keyEpoch: keyEpoch,
      opId: opId ?? _uuid.v4(),
      authorMemberId: memberId,
      authorKeyId: signer.keyId,
      authorSeq: nextAuthorSeq,
      prevAuthorHash: lastEnvelopeHash,
    );
    final envelope = await signer.buildEnvelope(
      header,
      frameBody(Uint8List.fromList(utf8.encode(payloadJson))),
    );
    if (advance) {
      nextAuthorSeq += 1;
      lastEnvelopeHash = envelopeHash(envelope);
    }
    return envelope;
  }
}
