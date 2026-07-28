/// A bare author that mints real, correctly chained envelopes.
///
/// The twin of `backend/tests/sync/builders.py`'s `SpecDevice`: it exists for
/// the transport contract tests, which care about the header, the chain, the
/// dedupe key and the certificate, and not at all about what a device does with
/// the result.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

class AuthorFixture {
  AuthorFixture._(this.memberId, this.signer, this.kexPk);

  static Future<AuthorFixture> create({String? memberId, Uint8List? seed}) async {
    final signSeed = seed ?? Uint8List.fromList(List<int>.generate(32, (index) => index + 1));
    final signer = await EnvelopeSigner.fromSeed(signSeed);
    // A distinct KEX seed derived from the same one: separate keys per F8/F19,
    // still reproducible run to run.
    final kexKeyPair = await X25519().newKeyPairFromSeed(
      Uint8List.fromList([for (final byte in signSeed) (byte + 0x5A) % 256]),
    );
    final kexPublicKey = await kexKeyPair.extractPublicKey();
    return AuthorFixture._(
      memberId ?? _uuid.v4(),
      signer,
      Uint8List.fromList(kexPublicKey.bytes),
    );
  }

  final String memberId;
  final EnvelopeSigner signer;
  final Uint8List kexPk;

  int nextAuthorSeq = 1;
  Uint8List lastEnvelopeHash = Uint8List(prevAuthorHashBytes);

  Uint8List get signPk => signer.signPublicKey;

  /// Answer a transport proof-of-possession challenge.
  Future<Uint8List> signChallenge(Uint8List nonce) => signer.signBytes(
        domainSeparated(
          signingDomainAuthChallengeV1,
          [uuidToBytes(memberId), nonce],
        ),
      );

  /// Sign a Grant certificate with this author's *own* key.
  ///
  /// What an owning Device does when it delegates a lesser role — and the reason
  /// authority is checked against the envelope's author: a member-signed Grant is
  /// only ever authored by the member whose authority it claims.
  Future<Uint8List> signGrantCertificateBytes(Uint8List certBytes) =>
      signer.signBytes(domainSeparated(signingDomainGrantV1, [certBytes]));

  /// Sign a Revoke certificate with this author's own key.
  Future<Uint8List> signRevokeCertificateBytes(Uint8List certBytes) =>
      signer.signBytes(domainSeparated(signingDomainRevokeV1, [certBytes]));

  Future<Uint8List> nextEnvelope(
    String workspaceId, {
    String? opId,
    int suite = suitePlaintextV1,
    int opClass = opClassContent,
    int keyEpoch = 0,
    String payloadJson = '{"collection":"test"}',
    Uint8List? payload,
    int? authorSeq,
    bool advance = true,
  }) =>
      nextEnvelopeWithBody(
        workspaceId,
        frameBody(payload ?? Uint8List.fromList(utf8.encode(payloadJson))),
        opId: opId,
        suite: suite,
        opClass: opClass,
        keyEpoch: keyEpoch,
        authorSeq: authorSeq,
        advance: advance,
      );

  /// Sign an envelope over a body given verbatim.
  ///
  /// The escape hatch for bodies `frameBody` cannot produce — an illegal padded
  /// length, a length prefix that overruns. Signed over the bad body, so only
  /// the framing rule can be what fires.
  Future<Uint8List> nextEnvelopeWithBody(
    String workspaceId,
    Uint8List body, {
    String? opId,
    int suite = suitePlaintextV1,
    int opClass = opClassContent,
    int keyEpoch = 0,
    int? authorSeq,
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
      authorSeq: authorSeq ?? nextAuthorSeq,
      prevAuthorHash: lastEnvelopeHash,
    );
    final envelope = await signer.buildEnvelope(header, body);
    if (advance) {
      nextAuthorSeq += 1;
      lastEnvelopeHash = envelopeHash(envelope);
    }
    return envelope;
  }
}

/// A v1-shaped escrow blob with filler ciphertext.
///
/// The server never parses a blob, so a route-contract test only needs the
/// right *shape*. Unwrapping for real is exercised by the escrow tests, where
/// the KDF and the AEAD actually run.
Uint8List harnessEscrowBlob([int fill = 0x5C]) {
  final blob = Uint8List(escrowBlobBytes);
  blob.setRange(0, 4, escrowBlobMagic);
  ByteData.view(blob.buffer)
    ..setUint32(4, argon2idFloorMemoryKib, Endian.big)
    ..setUint32(8, argon2idFloorTimeCost, Endian.big);
  blob[12] = argon2idFloorParallelism;
  blob.fillRange(13, blob.length, fill);
  return blob;
}
