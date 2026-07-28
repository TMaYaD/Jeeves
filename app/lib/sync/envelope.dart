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
///   suite            u8        0      1   0x00 = plaintext_v1
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
/// body      = u32 payload_len || payload || zero padding
/// signature = Ed25519(sk_author, "jeeves/op/v1" || header || body)
/// envelope  = header || body || signature
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

// --- Suites ------------------------------------------------------------------

/// plaintext_v1 — no AEAD, Ed25519 signature only. The suite this slice speaks.
const int suitePlaintextV1 = 0x00;

/// aead_v1 — XChaCha20-Poly1305 + Ed25519. Reserved for #554, never emitted here.
const int suiteAeadV1 = 0x01;

/// Suites this build implements. Anything else is fail-closed (review F21).
const Set<int> servedSuites = {suitePlaintextV1};

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

/// Control arrived with #548 and carries exactly one type, `member_register`
/// (see `control_payload.dart`); every other control type is still fail-closed.
/// Suggestion is #557, compaction and prune #555.
const Set<int> servedOpClasses = {opClassContent, opClassControl};

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

// --- Failure surface -------------------------------------------------------------

/// Why an op was refused. The `code` strings are the contract shared with the
/// Python codec and with the golden vectors: both suites assert the *same*
/// rejection, not merely that something threw.
enum SyncRejectionReason {
  truncatedEnvelope('truncated_envelope'),
  envelopeTooShort('envelope_too_short'),
  unsupportedSuite('unsupported_suite'),
  unsupportedOpClass('unsupported_op_class'),
  invalidBodyLength('invalid_body_length'),
  payloadOverrunsBody('payload_overruns_body'),
  nonZeroPadding('non_zero_padding'),
  badSignature('bad_signature'),
  workspaceMismatch('workspace_mismatch'),

  /// No *verified* MemberRegister has taught this device the author's key.
  ///
  /// Replaces the pre-#548 `unknown_author_key`, which meant "not in the
  /// registry the server served us". A registry miss and a chain miss are
  /// different claims: this one says nothing signed by Root vouches for the
  /// author, whatever the server's registry says.
  memberNotChainedToRoot('member_not_chained_to_root'),
  badRootSignature('bad_root_signature'),

  /// A Grant's granter did not sign it, under the Grant's own domain.
  badGrantSignature('bad_grant_signature'),

  /// A Revoke's revoker did not sign it, under the Revoke's own domain.
  badRevokeSignature('bad_revoke_signature'),

  /// A role outside owner/participant/compactor/suggester. Fails closed: a role
  /// a verifier cannot interpret is never read as a permissive default.
  unknownRole('unknown_role'),

  /// An `owner` Grant minted by anything but Root — a pure document invariant,
  /// so it is refused at decode wherever the bytes are held (ADR-0031).
  ownerGrantRequiresRoot('owner_grant_requires_root'),

  /// An `owner` Grant revoked by anything but Root. Needs the target Grant's
  /// role, so unlike its mint counterpart this one is a *stateful* verdict.
  ownerRevokeRequiresRoot('owner_revoke_requires_root'),

  /// A Grant naming a grantee this device cannot resolve. Fail-closed: never held
  /// as a dangling forward reference.
  unknownGrantee('unknown_grantee'),

  /// A Revoke naming a Grant this device cannot resolve. Distinct from
  /// [unknownGrantee] because a Revoke names a `grant_id`: conflating the two
  /// leaves a client unable to tell a failed revocation from an invalid grantee.
  unknownGrant('unknown_grant'),

  /// A Grant to a non-Device member in the `user_preferences` Workspace — the
  /// client-side half of "every Device, no Service ever".
  serviceGrantForbidden('service_grant_forbidden'),

  /// The author of a content op holds no Grant permitting its `op_class` at the
  /// op's own server seq. Logged-but-refused: the row is written and advances
  /// per-author accounting, and the payload never applies.
  noLiveGrant('no_live_grant'),

  /// A content op built against a `key_epoch` below the Workspace's persisted
  /// monotone floor. Authoring-side today; #554's rotate ops raise the floor.
  keyEpochBelowFloor('key_epoch_below_floor'),
  malformedControlPayload('malformed_control_payload'),
  unsupportedControlType('unsupported_control_type'),

  /// The control chain skipped or restarted under our feet — including the
  /// genesis-only zero-link rule in both directions.
  controlChainBreak('control_chain_break'),

  /// Two control ops name the same predecessor. The tie-break picks a winner and
  /// this quarantines the losing branch, and everything chaining through it.
  controlChainFork('control_chain_fork'),
  unrepresentableAuthorSeq('unrepresentable_author_seq'),
  malformedPayload('malformed_payload'),
  malformedMemberIdHex('malformed_member_id_hex'),
  hlcInTheFuture('hlc_in_the_future'),
  hlcMemberIsNotAuthor('hlc_member_is_not_author'),

  // --- Per-author chain rules (client-only) ---------------------------------
  //
  // These six are *stateful receiver policy*, not per-envelope codec rules: the
  // same envelope is chain-valid for one device and a gap for another, depending
  // on what each has already received. The server never quarantines and the
  // Python codec has no chain state, so — unlike every code above — these carry
  // no golden vector and no backend twin. See `chain_verifier.dart`.

  /// `author_seq` is beyond the verified head + 1.
  authorChainGap('author_chain_gap'),

  /// Right position, wrong `prev_author_hash`.
  prevAuthorHashMismatch('prev_author_hash_mismatch'),

  /// A position already held, served with different bytes.
  authorChainRewrite('author_chain_rewrite'),

  /// The same `(author, op_id)` under a different position or different bytes.
  duplicateOpIdDivergence('duplicate_op_id_divergence'),

  /// A pull served an op at or below the cursor, in a slot this device does not
  /// already hold byte-identically.
  staleReplayedOp('stale_replayed_op'),

  /// An envelope this device authored, served back with different bytes than the
  /// outbox row it was signed into. The local copy stands.
  ownWritesDivergence('own_writes_divergence');

  const SyncRejectionReason(this.code);

  /// The stable machine code written into the quarantine row and the vectors.
  final String code;

  static SyncRejectionReason byCode(String code) =>
      SyncRejectionReason.values.firstWhere((reason) => reason.code == code);
}

/// A fail-closed refusal: the op is never applied, always surfaced.
class SyncRejection implements Exception {
  const SyncRejection(this.reason, this.message);

  final SyncRejectionReason reason;
  final String message;

  @override
  String toString() => 'SyncRejection(${reason.code}): $message';
}

// --- Header ----------------------------------------------------------------------

final Uint8List _zero32 = Uint8List(32);
final Uint8List _zero24 = Uint8List(24);

/// The 158 fixed bytes every op carries in the clear.
class OpHeader {
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
  })  : prevAuthorHash = prevAuthorHash ?? _zero32,
        observedHead = observedHead ?? _zero32,
        nonce = nonce ?? _zero24;

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

  /// Fail closed on any suite or op class this build does not serve.
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

/// First 8 bytes of SHA-256 over the raw 32-byte Ed25519 public key.
///
/// The server derives this the same way and stores what it derived, never a
/// client's claim; the client recomputes it locally for the header.
Uint8List deriveKeyId(Uint8List signPublicKey) {
  _requireLength(signPublicKey, signPublicKeyBytes, 'sign_pk');
  return Uint8List.fromList(
    crypto.sha256.convert(signPublicKey).bytes.sublist(0, authorKeyIdBytes),
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
Future<void> verifyEnvelope(Uint8List envelope, Uint8List signPublicKey) async {
  final parts = splitEnvelope(envelope);
  final ok = await Ed25519().verify(
    signingInput(parts.header, parts.body),
    signature: Signature(
      parts.signature,
      publicKey: SimplePublicKey(signPublicKey, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) {
    throw const SyncRejection(
      SyncRejectionReason.badSignature,
      'Ed25519 signature does not verify',
    );
  }
}
