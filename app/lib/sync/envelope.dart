/// v1 op envelope codec — the client half of the Minimal Sync Server's
/// protocol identity (ADR-0026, proposal § Envelope, security review F6).
///
/// This is a deliberate mirror of `backend/app/sync/envelope.py`. Both are
/// pinned byte-for-byte by `spec/sync/envelope_v1_vectors.json`, so a change on
/// one side that the other did not make fails a test rather than forking the
/// protocol quietly.
///
/// ```
/// header (canonical, fixed order; fixed-width fields, big-endian integers)
///                           offset  size
///   suite            u8        0      1   0x00 = plaintext_v1, 0x01 = aead_v1
///   op_class         u8        1      1   1=content 2=control 3=suggestion
///                                         4=compaction 5=prune
///   workspace_id     16B       2     16
///   key_epoch        u32      18      4
///   op_id            16B      22     16
///   author_member_id 16B      38     16
///   author_key_id    8B       54      8
///   author_seq       u64      62      8
///   prev_author_hash 32B      70     32
///   observed_head    32B     102     32   reserved, zero in v1
///   nonce            24B     134     24   zero under suite 0x00
///                         total = 158 bytes
///
/// plaintext body = u32 payload_len || payload || zero padding
/// aead_v1 body   = XChaCha20-Poly1305(K_{w,epoch}, header.nonce,
///                      aad = the 158 serialized header bytes exactly,
///                      plaintext = the *same* framed body)
/// signature      = Ed25519(sk_author, "jeeves/op/v1" || header || body)
/// envelope       = header || body || signature
/// ```
///
/// **`aead_v1` is a body wrapper and nothing else.** No offset moves, no field is
/// added, and the framed plaintext under 0x01 is byte for byte what 0x00 would
/// have carried in the clear — so [parseBody]'s three padding rules run on the
/// decrypted plaintext through the same code path, which is how the
/// covert-channel and tamper duty moves *inside* the AEAD rather than being
/// duplicated beside it. The AAD is the literal header, so the suite, the
/// `key_epoch` and the nonce are all bound with no second binding to keep in step.
///
/// One rule is suite-conditional, and only one: a 0x01 body is 16 bytes longer
/// than the size class it pads to (the Poly1305 tag), so wire-legality is
/// [isLegalBodyLengthForSuite] rather than [isLegalBodyLength].
///
/// **Two op classes are `plaintext_v1` for ever**, for one reason: the server has
/// to *act* on their payloads and holds no key. Control ops (review F2) are the
/// first — it materialises memberships, Grants and rotations out of them. Prune
/// ops (#555) are the second — it stamps `ops.compacted_by` from their target
/// enumeration, which names transport seqs and envelope hashes and carries no
/// content. Both pairs are refused by both codecs, under their own codes:
/// [SyncRejectionReason.encryptedControlOp] and
/// [SyncRejectionReason.encryptedPruneOp].
///
/// The rule runs the **opposite** way for the classes that carry entity content.
/// A class-1 or class-4 body at suite 0x00 whose `key_epoch` this device holds a
/// key for is a downgrade, refused as
/// [SyncRejectionReason.plaintextAtEncryptedEpoch] — see
/// [plaintextRefusedAtKeyedEpochOpClasses]. Class 4 is in that family because a
/// compaction op carries the whole joined state of an entity.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'sync_rejection.dart';

export 'sync_rejection.dart';

// --- Suites ------------------------------------------------------------------

/// plaintext_v1 — no AEAD, Ed25519 signature only.
const int suitePlaintextV1 = 0x00;

/// aead_v1 — XChaCha20-Poly1305 over the framed body, plus the Ed25519 signature.
const int suiteAeadV1 = 0x01;

/// Suites this build implements. Anything else is fail-closed (review F21).
const Set<int> servedSuites = {suitePlaintextV1, suiteAeadV1};

// --- Op classes ---------------------------------------------------------------

const int opClassContent = 1;
const int opClassControl = 2;
const int opClassSuggestion = 3;
const int opClassCompaction = 4;
const int opClassPrune = 5;

/// Every op class the protocol names. A value outside this set is *unknown*; a
/// value inside it but outside [servedOpClasses] is *not yet implemented*.
/// Both quarantine, and a receiver deliberately cannot tell them apart.
const Set<int> knownOpClasses = {
  opClassContent,
  opClassControl,
  opClassSuggestion,
  opClassCompaction,
  opClassPrune,
};

/// Compaction and prune arrived with #555; suggestion is still fail-closed until
/// #557.
const Set<int> servedOpClasses = {
  opClassContent,
  opClassControl,
  opClassCompaction,
  opClassPrune,
};

/// Op classes the server must be able to **read**, and which are therefore
/// `plaintext_v1` for ever.
///
/// Not a served/unserved question and so not a subset of anything above: both
/// halves of `(0x01, class)` are served and the *pair* is forbidden. Control
/// because the server materialises memberships and Grants; prune because it
/// stamps `compacted_by` from the target enumeration. Neither payload carries
/// entity content, which is what makes the exemption safe.
const Set<int> mustStayPlaintextOpClasses = {opClassControl, opClassPrune};

/// Op classes that carry entity content, and for which a `plaintext_v1` body at a
/// **keyed** epoch is a downgrade rather than history.
///
/// Class 4 is here for the same reason class 1 is, only more so: a compaction op
/// carries the whole joined state of an entity at every original author's clock.
/// The two sets happen to be complements over `{1, 2, 4, 5}` today; that is
/// arithmetic, not a rule — class 3 joins the content family when #557 serves it
/// and belongs to neither set until then.
const Set<int> plaintextRefusedAtKeyedEpochOpClasses = {
  opClassContent,
  opClassCompaction,
};

// --- Sizes ---------------------------------------------------------------------

const int headerLengthBytes = 158;
const int signatureLengthBytes = 64;
const int envelopeOverheadBytes = headerLengthBytes + signatureLengthBytes;

const int workspaceIdBytes = 16;
const int opIdBytes = 16;
const int authorMemberIdBytes = 16;
const int authorKeyIdBytes = 8;
const int prevAuthorHashBytes = 32;
const int observedHeadBytes = 32;
const int nonceBytes = 24;
const int signPublicKeyBytes = 32;

/// The Poly1305 tag every AEAD ciphertext here carries, appended.
///
/// One constant for the envelope body, the KeyWrap and the escrow blob: they all
/// use XChaCha20-Poly1305, and three copies of 16 is how one of them ends up
/// disagreeing.
const int aeadTagBytes = 16;

/// A Workspace content key `K_{w,epoch}` — random 256 bits, never derived.
const int workspaceKeyBytes = 32;

const int _offsetSuite = 0;
const int _offsetOpClass = 1;
const int _offsetWorkspaceId = 2;
const int _offsetKeyEpoch = 18;
const int _offsetOpId = 22;
const int _offsetAuthorMemberId = 38;
const int _offsetAuthorKeyId = 54;
const int _offsetAuthorSeq = 62;
const int _offsetPrevAuthorHash = 70;
const int _offsetObservedHead = 102;
const int _offsetNonce = 134;

/// Every signing use of every key is domain-separated (review F7). A signature
/// made for one use must never verify for another, so each has its own prefix.
const String signingDomainOpV1 = 'jeeves/op/v1';

/// Root over a registration certificate — see `control_payload.dart`.
const String signingDomainMemberRegisterV1 = 'jeeves/member-register/v1';

/// Root over a Workspace genesis certificate.
const String signingDomainWorkspaceGenesisV1 = 'jeeves/workspace-genesis/v1';

/// Root, or an owning Member, over a Grant certificate.
const String signingDomainGrantV1 = 'jeeves/grant/v1';

/// Root, or an owning Member, over a Revoke certificate. Separate from the Grant
/// domain so an unmaking can never be replayed as a making.
const String signingDomainRevokeV1 = 'jeeves/revoke/v1';

/// A device over a transport proof-of-possession challenge.
const String signingDomainAuthChallengeV1 = 'jeeves/auth-challenge/v1';

/// Root over a recovery escrow record — see `recovery_escrow.dart`.
const String signingDomainEscrowV1 = 'jeeves/escrow/v1';

// --- Body framing (review F17) --------------------------------------------------

const int payloadLengthPrefixBytes = 4;

/// Padded body sizes below the oversize threshold.
///
/// **Measured and left alone under #554.** A full-day convergence corpus authors
/// 61 content ops: 32 pad to 256 and 29 to 1024, and 25 of those 29 have a framed
/// length in 257–512 — so 256→1024 *is* the common jump, exactly as the proposal
/// suspected. A 512 class was still refused. Padding classes are a confidentiality
/// mechanism, not a bandwidth one: splitting the bucket would hand an observer one
/// more bit per op about how large its payload is, and buy back ~13 KiB a day. On
/// an issue whose subject is confidentiality that is the wrong side of the trade,
/// and the coarse bucket is the padding doing its job — collapsing 41% of a day's
/// ops into a class indistinguishable from the largest ones.
const List<int> bodySizeClassesBytes = [256, 1024, 4096, 16384];

/// Above the largest size class a body rounds up to the next multiple of this,
/// with no hard cap — #550's notes fields can be large.
const int bodyOversizeMultipleBytes = 16384;

/// The shortest envelope that can possibly be well-formed: header ‖ the
/// smallest body size class ‖ signature.
///
/// Every legal body is padded up to a size class, so `envelopeOverheadBytes + 1`
/// is not the floor — 256 is the smallest body there is. Derived rather than
/// written out so the number cannot drift from the padding rule it follows from.
final int minimumEnvelopeBytes =
    headerLengthBytes + bodySizeClassesBytes.first + signatureLengthBytes;

/// [minimumEnvelopeBytes], made suite-aware by the one thing that differs.
///
/// The server's content-blind floor: under 0x01 the smallest legal body is the
/// smallest size class *plus the tag*, so a floor that stayed at the plaintext
/// number would let a 16-byte-short encrypted envelope into the log for every
/// puller to quarantine. It reads the suite out of the header, which it already
/// parses, and still never looks at a body byte.
int minimumEnvelopeBytesForSuite(int suite) =>
    minimumEnvelopeBytes + (suite == suiteAeadV1 ? aeadTagBytes : 0);

// --- Failure surface -------------------------------------------------------------


// --- Header ----------------------------------------------------------------------

/// The 158 fixed bytes every op carries in the clear.
class OpHeader {
  /// An omitted [prevAuthorHash]/[observedHead]/[nonce] gets its *own* zero
  /// buffer, not a shared one: `Uint8List` is mutable, so a single in-place
  /// write through one header's default would otherwise silently rewrite the
  /// defaults of every other header in the process. Caller-provided values are
  /// taken as given — the caller owns those bytes.
  OpHeader({
    required this.workspaceId,
    required this.opId,
    required this.authorMemberId,
    required this.authorKeyId,
    required this.authorSeq,
    this.suite = suitePlaintextV1,
    this.opClass = opClassContent,
    this.keyEpoch = 0,
    Uint8List? prevAuthorHash,
    Uint8List? observedHead,
    Uint8List? nonce,
  })  : prevAuthorHash = prevAuthorHash ?? Uint8List(prevAuthorHashBytes),
        observedHead = observedHead ?? Uint8List(observedHeadBytes),
        nonce = nonce ?? Uint8List(nonceBytes);

  final int suite;
  final int opClass;
  final String workspaceId;
  final int keyEpoch;
  final String opId;
  final String authorMemberId;
  final Uint8List authorKeyId;
  final int authorSeq;
  final Uint8List prevAuthorHash;
  final Uint8List observedHead;
  final Uint8List nonce;

  Uint8List serialize() {
    _requireLength(authorKeyId, authorKeyIdBytes, 'author_key_id');
    _requireLength(prevAuthorHash, prevAuthorHashBytes, 'prev_author_hash');
    _requireLength(observedHead, observedHeadBytes, 'observed_head');
    _requireLength(nonce, nonceBytes, 'nonce');

    final bytes = Uint8List(headerLengthBytes);
    final view = ByteData.view(bytes.buffer);
    bytes[_offsetSuite] = suite;
    bytes[_offsetOpClass] = opClass;
    bytes.setRange(
      _offsetWorkspaceId,
      _offsetWorkspaceId + workspaceIdBytes,
      uuidToBytes(workspaceId),
    );
    view.setUint32(_offsetKeyEpoch, keyEpoch, Endian.big);
    bytes.setRange(
      _offsetOpId,
      _offsetOpId + opIdBytes,
      uuidToBytes(opId),
    );
    bytes.setRange(
      _offsetAuthorMemberId,
      _offsetAuthorMemberId + authorMemberIdBytes,
      uuidToBytes(authorMemberId),
    );
    bytes.setRange(
      _offsetAuthorKeyId,
      _offsetAuthorKeyId + authorKeyIdBytes,
      authorKeyId,
    );
    _writeUint64(view, _offsetAuthorSeq, authorSeq);
    bytes.setRange(
      _offsetPrevAuthorHash,
      _offsetPrevAuthorHash + prevAuthorHashBytes,
      prevAuthorHash,
    );
    bytes.setRange(
      _offsetObservedHead,
      _offsetObservedHead + observedHeadBytes,
      observedHead,
    );
    bytes.setRange(_offsetNonce, _offsetNonce + nonceBytes, nonce);
    return bytes;
  }

  static OpHeader parse(Uint8List raw) {
    if (raw.length < headerLengthBytes) {
      throw SyncRejection(
        SyncRejectionReason.truncatedEnvelope,
        'header is ${raw.length} bytes, expected $headerLengthBytes',
      );
    }
    final view = ByteData.view(raw.buffer, raw.offsetInBytes, headerLengthBytes);
    return OpHeader(
      suite: raw[_offsetSuite],
      opClass: raw[_offsetOpClass],
      workspaceId: _uuidAt(raw, _offsetWorkspaceId),
      keyEpoch: view.getUint32(_offsetKeyEpoch, Endian.big),
      opId: _uuidAt(raw, _offsetOpId),
      authorMemberId: _uuidAt(raw, _offsetAuthorMemberId),
      authorKeyId: _sliceOf(raw, _offsetAuthorKeyId, authorKeyIdBytes),
      authorSeq: _readUint64(view, _offsetAuthorSeq),
      prevAuthorHash: _sliceOf(raw, _offsetPrevAuthorHash, prevAuthorHashBytes),
      observedHead: _sliceOf(raw, _offsetObservedHead, observedHeadBytes),
      nonce: _sliceOf(raw, _offsetNonce, nonceBytes),
    );
  }

  /// Fail closed on any suite or op class this build does not serve, and on the
  /// `(suite, op_class)` pairs the protocol forbids outright.
  ///
  /// Two pairs, one per member of [mustStayPlaintextOpClasses], and each gets its
  /// own code rather than a shared one: a client that saw an encrypted prune has
  /// learned something different about its server than one that saw an encrypted
  /// control op, and the remediation differs with it.
  void checkServed() {
    if (!servedSuites.contains(suite)) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedSuite,
        'suite 0x${suite.toRadixString(16).padLeft(2, '0')} is not served',
      );
    }
    if (!servedOpClasses.contains(opClass)) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedOpClass,
        'op_class $opClass is not served',
      );
    }
    if (suite == suiteAeadV1 && opClass == opClassControl) {
      // Not a served/unserved question, and so not expressible as a set: both
      // halves are served, and the *pair* is forbidden for ever. See
      // [SyncRejectionReason.encryptedControlOp].
      throw const SyncRejection(
        SyncRejectionReason.encryptedControlOp,
        'control ops are plaintext_v1 for ever: the server materialises their '
        'payloads and holds no key',
      );
    }
    if (suite == suiteAeadV1 && opClass == opClassPrune) {
      throw const SyncRejection(
        SyncRejectionReason.encryptedPruneOp,
        'prune ops are plaintext_v1 for ever: the server stamps compacted_by '
        'from their target enumeration and holds no key',
      );
    }
  }
}

// --- aead_v1: sealing and opening a body -------------------------------------

/// The AEAD the whole protocol uses: XChaCha20-Poly1305, as the escrow blob does.
final Cipher _bodyCipher = Xchacha20.poly1305Aead();

/// The 24 nonce bytes carried at [_offsetNonce] of a serialized header.
///
/// Read out of the literal header rather than passed alongside it: the nonce *is*
/// a header field, so a caller that could supply a different one would be sealing
/// under bytes the AAD does not cover.
Uint8List nonceOfHeader(Uint8List headerBytes) =>
    _sliceOf(headerBytes, _offsetNonce, nonceBytes);

/// Seal a framed body under `aead_v1`: `ciphertext || tag`.
///
/// [headerBytes] is both the AAD and the source of the nonce, so there is exactly
/// one place either can come from. The plaintext is the *already framed* body —
/// pad-then-encrypt — which is what puts [parseBody]'s padding rules inside the
/// AEAD instead of beside it.
///
/// Nothing here mints a nonce. Production draws 24 bytes from `Random.secure()`
/// at authoring and writes them into the header before it is serialized; the
/// golden vectors pin explicit nonce bytes. A seeded-nonce scheme would be
/// catastrophic under a stream cipher, so the seam is "the caller already chose,
/// and it is in the header" rather than an injectable entropy source.
Future<Uint8List> sealBody({
  required Uint8List headerBytes,
  required Uint8List framedBody,
  required Uint8List workspaceKey,
}) async {
  _requireLength(headerBytes, headerLengthBytes, 'header');
  _requireLength(workspaceKey, workspaceKeyBytes, 'workspace key');
  final box = await _bodyCipher.encrypt(
    framedBody,
    secretKey: SecretKey(workspaceKey),
    nonce: nonceOfHeader(headerBytes),
    aad: headerBytes,
  );
  return (BytesBuilder(copy: false)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .toBytes();
}

/// Open an `aead_v1` body back to its framed plaintext.
///
/// Throws [SyncRejectionReason.invalidBodyLength] for a body that is not a size
/// class plus a tag, and [SyncRejectionReason.aeadFailure] for anything the AEAD
/// refuses — a tampered ciphertext and a tampered header are the same verdict
/// here, because the header is the AAD and the codec cannot tell which of them
/// moved. Classifying them apart would be a guess.
Future<Uint8List> openBody({
  required Uint8List headerBytes,
  required Uint8List body,
  required Uint8List workspaceKey,
}) async {
  _requireLength(headerBytes, headerLengthBytes, 'header');
  _requireLength(workspaceKey, workspaceKeyBytes, 'workspace key');
  if (!isLegalBodyLengthForSuite(suiteAeadV1, body.length)) {
    throw SyncRejection(
      SyncRejectionReason.invalidBodyLength,
      'an aead_v1 body of ${body.length} bytes is not a size class plus a '
      '$aeadTagBytes-byte tag',
    );
  }
  final split = body.length - aeadTagBytes;
  try {
    return Uint8List.fromList(
      await _bodyCipher.decrypt(
        SecretBox(
          Uint8List.sublistView(body, 0, split),
          nonce: nonceOfHeader(headerBytes),
          mac: Mac(Uint8List.sublistView(body, split)),
        ),
        secretKey: SecretKey(workspaceKey),
        aad: headerBytes,
      ),
    );
  } on SecretBoxAuthenticationError catch (error) {
    throw SyncRejection(
      SyncRejectionReason.aeadFailure,
      'the aead_v1 body did not authenticate under the epoch key this device '
      'holds: $error',
    );
  } on Object catch (error) {
    // Any other failure out of the cipher on these untrusted bytes gets the same
    // fail-closed verdict: the body reached `decrypt` past the length gate, so a
    // raw throw here would land in `unexpectedReceiveFailure` instead of the
    // accusation the codec owes the caller.
    throw SyncRejection(
      SyncRejectionReason.aeadFailure,
      'the aead_v1 body could not be opened under the epoch key this device '
      'holds: $error',
    );
  }
}

void _requireLength(Uint8List value, int expected, String what) {
  if (value.length != expected) {
    throw ArgumentError('$what must be $expected bytes, got ${value.length}');
  }
}

Uint8List _sliceOf(Uint8List source, int offset, int length) =>
    Uint8List.fromList(source.sublist(offset, offset + length));

final RegExp _canonicalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// True iff [value] is a canonical lowercase UUID string: 8-4-4-4-12 hex.
///
/// The one spelling of a UUID this protocol accepts anywhere — header ids here,
/// and the payload's entity `id` in `op_payload.dart`. Python's `uuid.UUID`
/// would also swallow braces, a `urn:uuid:` prefix and stray dashes; both codecs
/// reject those rather than normalise them, for the same reason an uppercase HLC
/// member id is rejected. A spelling the two codecs disagree about is a
/// convergence bug, not a leniency.
bool isCanonicalUuid(String value) => _canonicalUuidPattern.hasMatch(value);

/// Length-then-content byte comparison.
///
/// Shared rather than re-declared per file: half the sync spine compares hashes,
/// key ids and envelopes, and a private copy per module is how one of them ends
/// up subtly different from the rest.
bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// The 16 raw bytes of a canonical lowercase UUID string.
///
/// Deliberately *not* `package:uuid`'s parser: that one enforces the RFC 4122
/// version and variant nibbles, and these header fields are 16 opaque bytes.
/// A server can put anything there and the client must be able to read it back
/// rather than crash — so only the textual shape is enforced.
Uint8List uuidToBytes(String uuid) {
  if (!_canonicalUuidPattern.hasMatch(uuid)) {
    throw ArgumentError('"$uuid" is not a canonical lowercase UUID');
  }
  final hex = uuid.replaceAll('-', '');
  final bytes = Uint8List(16);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}

/// The canonical lowercase UUID string for 16 bytes at [offset].
String bytesToUuid(Uint8List source, [int offset = 0]) {
  final hex = StringBuffer();
  for (var index = 0; index < 16; index++) {
    hex.write(source[offset + index].toRadixString(16).padLeft(2, '0'));
  }
  final digits = hex.toString();
  return '${digits.substring(0, 8)}-${digits.substring(8, 12)}-'
      '${digits.substring(12, 16)}-${digits.substring(16, 20)}-'
      '${digits.substring(20)}';
}

String _uuidAt(Uint8List source, int offset) => bytesToUuid(source, offset);

/// The largest `author_seq` this client can represent: 2^53 - 1.
///
/// `dart:typed_data`'s 64-bit accessors do not exist on the web, so the u64 is
/// split into two 32-bit halves and recombined — exact up to 2^53. The header
/// field stays a true u64 on the wire; what this bounds is what a *client* will
/// accept. Reaching it would take an author 9 quadrillion ops, so a header
/// above it is a broken or hostile server, and it is refused rather than
/// silently rounded into a different sequence number.
const int maxRepresentableAuthorSeq = 0x1FFFFFFFFFFFFF;

void _writeUint64(ByteData view, int offset, int value) {
  if (value < 0 || value > maxRepresentableAuthorSeq) {
    throw ArgumentError('author_seq $value exceeds $maxRepresentableAuthorSeq');
  }
  view.setUint32(offset, value ~/ 0x100000000, Endian.big);
  view.setUint32(offset + 4, value % 0x100000000, Endian.big);
}

int _readUint64(ByteData view, int offset) {
  final high = view.getUint32(offset, Endian.big);
  if (high > maxRepresentableAuthorSeq ~/ 0x100000000) {
    throw SyncRejection(
      SyncRejectionReason.unrepresentableAuthorSeq,
      'author_seq exceeds $maxRepresentableAuthorSeq',
    );
  }
  return high * 0x100000000 + view.getUint32(offset + 4, Endian.big);
}

/// First 8 bytes of SHA-256 over a raw 32-byte public key.
///
/// The one key-id derivation in the protocol, used for both key ids a Member
/// carries — the Ed25519 signing key's and the X25519 KEX key's, which are the
/// same width. The server derives this the same way and stores what it derived,
/// never a client's claim; the client recomputes it locally for the header.
Uint8List deriveKeyId(Uint8List publicKey) {
  _requireLength(publicKey, signPublicKeyBytes, 'public key');
  return Uint8List.fromList(
    crypto.sha256.convert(publicKey).bytes.sublist(0, authorKeyIdBytes),
  );
}

/// SHA-256 over the full envelope bytes — the link in the per-author chain.
Uint8List envelopeHash(Uint8List envelope) =>
    Uint8List.fromList(crypto.sha256.convert(envelope).bytes);

// --- Body framing -----------------------------------------------------------------

/// Smallest legal body length that holds [framedLengthBytes].
int paddedBodyLength(int framedLengthBytes) {
  for (final sizeClass in bodySizeClassesBytes) {
    if (framedLengthBytes <= sizeClass) return sizeClass;
  }
  final multiples =
      (framedLengthBytes + bodyOversizeMultipleBytes - 1) ~/ bodyOversizeMultipleBytes;
  return multiples * bodyOversizeMultipleBytes;
}

/// True iff [bodyLengthBytes] is a size class or an exact 16 KiB multiple.
bool isLegalBodyLength(int bodyLengthBytes) {
  if (bodySizeClassesBytes.contains(bodyLengthBytes)) return true;
  return bodyLengthBytes > bodySizeClassesBytes.last &&
      bodyLengthBytes % bodyOversizeMultipleBytes == 0;
}

/// [isLegalBodyLength], made suite-aware — **the one suite-conditional rule**.
///
/// A 0x01 body is the padded plaintext plus the Poly1305 tag, so its legal lengths
/// are the plaintext ones shifted by 16. Expressed as a shift rather than as a
/// second table so a change to the size classes moves both suites at once.
bool isLegalBodyLengthForSuite(int suite, int bodyLengthBytes) {
  if (suite != suiteAeadV1) return isLegalBodyLength(bodyLengthBytes);
  return bodyLengthBytes > aeadTagBytes &&
      isLegalBodyLength(bodyLengthBytes - aeadTagBytes);
}

/// `u32 payload_len || payload || 0x00 padding` to the next legal length.
Uint8List frameBody(Uint8List payload) {
  final framedLength = payloadLengthPrefixBytes + payload.length;
  final body = Uint8List(paddedBodyLength(framedLength));
  ByteData.view(body.buffer).setUint32(0, payload.length, Endian.big);
  body.setRange(payloadLengthPrefixBytes, framedLength, payload);
  return body;
}

/// Unframe a body, enforcing the three mandatory padding rules.
///
/// All three are fail-closed: a violation quarantines the op as malformed on
/// the same surface as an unknown suite. Zero-padding verification closes the
/// covert-channel and tamper gap that AEAD will close under suite 0x01. The
/// server is content-blind and never runs this, so it is the pulling client's
/// duty — this function is that duty.
Uint8List parseBody(Uint8List body) {
  if (!isLegalBodyLength(body.length)) {
    throw SyncRejection(
      SyncRejectionReason.invalidBodyLength,
      'body is ${body.length} bytes: neither a size class nor a '
      '$bodyOversizeMultipleBytes-byte multiple',
    );
  }
  final payloadLength = ByteData.view(
    body.buffer,
    body.offsetInBytes,
    payloadLengthPrefixBytes,
  ).getUint32(0, Endian.big);
  final paddingStart = payloadLengthPrefixBytes + payloadLength;
  if (paddingStart > body.length) {
    throw SyncRejection(
      SyncRejectionReason.payloadOverrunsBody,
      'payload_len $payloadLength overruns a ${body.length}-byte body',
    );
  }
  for (var index = paddingStart; index < body.length; index++) {
    if (body[index] != 0) {
      throw SyncRejection(
        SyncRejectionReason.nonZeroPadding,
        'padding byte at $index is 0x${body[index].toRadixString(16)}',
      );
    }
  }
  return Uint8List.fromList(body.sublist(payloadLengthPrefixBytes, paddingStart));
}

// --- Envelope ----------------------------------------------------------------------

/// `ascii(domain) || parts…` — the shape every signed artifact here takes.
///
/// One helper rather than one concatenation per call site: the domain prefix is
/// the whole defence against a signature made for one use verifying for
/// another, and it is exactly the kind of thing an open-coded `addAll` drops.
Uint8List domainSeparated(String domain, List<List<int>> parts) {
  final builder = BytesBuilder(copy: false)..add(ascii.encode(domain));
  for (final part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

Uint8List signingInput(Uint8List headerBytes, Uint8List body) =>
    domainSeparated(signingDomainOpV1, [headerBytes, body]);

/// Ed25519 over already-domain-separated bytes.
Future<Uint8List> signDomainSeparated(
  SimpleKeyPair keyPair,
  Uint8List message,
) async =>
    Uint8List.fromList(
      (await Ed25519().sign(message, keyPair: keyPair)).bytes,
    );

/// True iff [signature] is [publicKey]'s signature over [message].
Future<bool> verifyDomainSeparated(
  Uint8List message,
  Uint8List signature,
  Uint8List publicKey,
) async {
  if (signature.length != signatureLengthBytes ||
      publicKey.length != signPublicKeyBytes) {
    return false;
  }
  return Ed25519().verify(
    message,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
}

/// `(header bytes, body, signature)`, or a truncation refusal.
({Uint8List header, Uint8List body, Uint8List signature}) splitEnvelope(
  Uint8List envelope,
) {
  if (envelope.length <= envelopeOverheadBytes) {
    throw SyncRejection(
      SyncRejectionReason.truncatedEnvelope,
      'envelope is ${envelope.length} bytes, needs more than $envelopeOverheadBytes',
    );
  }
  return (
    header: Uint8List.fromList(envelope.sublist(0, headerLengthBytes)),
    body: Uint8List.fromList(
      envelope.sublist(headerLengthBytes, envelope.length - signatureLengthBytes),
    ),
    signature: Uint8List.fromList(
      envelope.sublist(envelope.length - signatureLengthBytes),
    ),
  );
}

/// Ed25519 over the domain-separated signing input, using the raw 32-byte seed.
class EnvelopeSigner {
  EnvelopeSigner._(this._keyPair, this.seed, this.signPublicKey);

  static final Ed25519 _algorithm = Ed25519();

  final SimpleKeyPair _keyPair;

  /// The 32 raw seed bytes. Retained so a Device can persist its identity
  /// through `DeviceKeyStore` and come back as the same Member after a
  /// relaunch — an Ed25519 keypair is exactly its seed.
  final Uint8List seed;
  final Uint8List signPublicKey;

  static Future<EnvelopeSigner> fromSeed(Uint8List seed) async {
    final keyPair = await _algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return EnvelopeSigner._(
      keyPair,
      Uint8List.fromList(seed),
      Uint8List.fromList(publicKey.bytes),
    );
  }

  Uint8List get keyId => deriveKeyId(signPublicKey);

  /// Sign already-domain-separated bytes — a challenge, not an envelope.
  Future<Uint8List> signBytes(Uint8List message) =>
      signDomainSeparated(_keyPair, message);

  Future<Uint8List> buildEnvelope(OpHeader header, Uint8List body) async {
    final headerBytes = header.serialize();
    final signature = await _algorithm.sign(
      signingInput(headerBytes, body),
      keyPair: _keyPair,
    );
    final envelope = Uint8List(headerBytes.length + body.length + signatureLengthBytes);
    envelope.setRange(0, headerBytes.length, headerBytes);
    envelope.setRange(headerBytes.length, headerBytes.length + body.length, body);
    envelope.setRange(headerBytes.length + body.length, envelope.length, signature.bytes);
    return envelope;
  }
}

/// Throws [SyncRejection] unless the Ed25519 signature checks out.
///
/// Goes through [verifyDomainSeparated] rather than calling `Ed25519().verify`
/// directly, so a signature or key of the wrong width is a fail-closed refusal
/// here instead of an unclassified throw out of the `cryptography` package —
/// which is what a caller passing a key from outside [MemberDirectory] would
/// otherwise get.
Future<void> verifyEnvelope(Uint8List envelope, Uint8List signPublicKey) async {
  final parts = splitEnvelope(envelope);
  final ok = await verifyDomainSeparated(
    signingInput(parts.header, parts.body),
    parts.signature,
    signPublicKey,
  );
  if (!ok) {
    throw const SyncRejection(
      SyncRejectionReason.badSignature,
      'Ed25519 signature does not verify',
    );
  }
}
