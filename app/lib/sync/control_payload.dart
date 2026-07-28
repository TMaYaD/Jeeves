/// The `op_class = 2` control payload format and the MemberRegister certificate.
///
/// A deliberate mirror of `backend/app/sync/control_payload.py`, pinned by
/// `spec/sync/envelope_v1_vectors.json`'s `control_vectors`. Control ops are the
/// one part of the log that is *not* opaque: they are unencrypted precisely so
/// that whoever holds the bytes — server or peer — can check a Member was
/// registered by Root before honouring anything it authored (ADR-0028, F2).
///
/// ```
/// {
///   "type": "member_register",
///   "prev_control_hash": "<hex64>",   // SHA-256 of the predecessor control
///                                     // op's *payload bytes*; all-zero only
///                                     // when no control op has been applied
///   "cert": "<base64 certificate bytes>",
///   "root_sig": "<base64 Ed25519(root_sk,
///                 'jeeves/member-register/v1' || cert_bytes)>"
/// }
/// ```
///
/// The chain link is over the predecessor's **payload bytes** — the unframed
/// payload `parseBody` returns — not the envelope and not a re-serialization.
/// The price of hashing bare bytes is that nothing outside them says what they
/// are, so **every control payload must be self-identifying: `type` is
/// mandatory in every control type, for ever.**
///
/// The certificate is signed bytes, never re-serialized JSON: a verifier checks
/// `root_sig` over the literal decoded blob and only then parses it.
///
/// **The domain string is the version.** The cert JSON carries no version
/// field; any field addition ships under a new signing domain, so old certs
/// stay verifiable and a downgrade is a signature failure rather than a parsing
/// ambiguity. `role`, `valid_from_epoch` and `granter` are deliberately absent:
/// role and provenance are Grant facts (#549), and every cert minted here is
/// implicitly epoch-0.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'envelope.dart';
import 'hlc.dart';

/// The one control type this slice serves. #549 opens up the rest.
const String controlTypeMemberRegister = 'member_register';
const Set<String> servedControlTypes = {controlTypeMemberRegister};

/// Members that are a Device. A Service member (#future) is the same cert with
/// a different kind, which is why the field exists before a second value does.
const String memberKindDevice = 'device';

const int prevControlHashBytes = 32;

/// Raw X25519 public key width. Separate from the signing key per F8/F19.
const int kexPublicKeyBytes = 32;

final Uint8List zeroPrevControlHash = Uint8List(prevControlHashBytes);

final RegExp _hex64Pattern = RegExp(r'^[0-9a-f]{64}$');

/// SHA-256 over a control op's payload bytes — the cross-author chain link.
Uint8List controlPayloadHash(Uint8List payloadBytes) =>
    Uint8List.fromList(crypto.sha256.convert(payloadBytes).bytes);

Uint8List _requireBase64(Object? raw, String what) {
  if (raw is! String) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what must be a base64 string',
    );
  }
  try {
    return base64Decode(raw);
  } on FormatException {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what is not valid base64',
    );
  }
}

Uint8List _requireKey(Object? raw, String what, int expectedBytes) {
  final decoded = _requireBase64(raw, what);
  if (decoded.length != expectedBytes) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what must be $expectedBytes bytes',
    );
  }
  return decoded;
}

String _requireCanonicalUuid(Object? raw, String what) {
  if (raw is! String || !isCanonicalUuid(raw)) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what must be a canonical lowercase UUID',
    );
  }
  return raw;
}

/// Root's statement that a Member's keys are that Member's keys.
class RegistrationCertificate {
  RegistrationCertificate({
    required this.workspaceId,
    required this.memberId,
    required this.signPk,
    required this.kexPk,
    required this.registeredAtHlc,
    this.memberKind = memberKindDevice,
  });

  final String workspaceId;
  final String memberId;
  final Uint8List signPk;
  final Uint8List kexPk;
  final Hlc registeredAtHlc;
  final String memberKind;

  Uint8List get signKeyId => deriveKeyId(signPk);

  /// The same derivation as the signing key id, over the KEX key. Carried
  /// explicitly so #549/#554 can rotate either key without changing the shape.
  Uint8List get kexKeyId => Uint8List.fromList(
        crypto.sha256.convert(kexPk).bytes.sublist(0, authorKeyIdBytes),
      );

  Map<String, Object?> toJson() => {
        'workspace_id': workspaceId,
        'member_id': memberId,
        'member_kind': memberKind,
        'sign_pk': base64Encode(signPk),
        'sign_key_id': base64Encode(signKeyId),
        'kex_pk': base64Encode(kexPk),
        'kex_key_id': base64Encode(kexKeyId),
        'registered_at_hlc': registeredAtHlc.toJson(),
      };

  /// UTF-8 JSON. These are the bytes Root signs and a verifier hashes — never a
  /// re-serialization of the parsed form.
  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static RegistrationCertificate decode(Uint8List certBytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(certBytes));
    } on FormatException {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert is not UTF-8 JSON',
      );
    }
    if (raw is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert must be a JSON object',
      );
    }

    final memberKind = raw['member_kind'];
    if (memberKind is! String || memberKind.isEmpty) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert member_kind must be a non-empty string',
      );
    }
    final certificate = RegistrationCertificate(
      workspaceId: _requireCanonicalUuid(raw['workspace_id'], 'cert workspace_id'),
      memberId: _requireCanonicalUuid(raw['member_id'], 'cert member_id'),
      signPk: _requireKey(raw['sign_pk'], 'cert sign_pk', signPublicKeyBytes),
      kexPk: _requireKey(raw['kex_pk'], 'cert kex_pk', kexPublicKeyBytes),
      registeredAtHlc: _decodeHlc(raw['registered_at_hlc']),
      memberKind: memberKind,
    );
    // The ids are derivations, so a claim that disagrees with the derivation is
    // a forgery attempt, not a variant spelling.
    if (!_sameBytes(
      _requireKey(raw['sign_key_id'], 'cert sign_key_id', authorKeyIdBytes),
      certificate.signKeyId,
    )) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert sign_key_id is not derived from sign_pk',
      );
    }
    if (!_sameBytes(
      _requireKey(raw['kex_key_id'], 'cert kex_key_id', authorKeyIdBytes),
      certificate.kexKeyId,
    )) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert kex_key_id is not derived from kex_pk',
      );
    }
    return certificate;
  }
}

Hlc _decodeHlc(Object? raw) {
  try {
    return Hlc.fromJson(raw);
  } on SyncRejection catch (rejection) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      'cert registered_at_hlc is malformed: ${rejection.message}',
    );
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// A parsed control op body.
///
/// [certBytes]/[rootSig] are populated only for `member_register`; a payload of
/// any other type parses far enough to name its type and its chain link, and is
/// then refused by whoever required a served type.
class ControlPayload {
  ControlPayload({
    required this.controlType,
    required this.prevControlHash,
    Uint8List? certBytes,
    Uint8List? rootSig,
  })  : certBytes = certBytes ?? Uint8List(0),
        rootSig = rootSig ?? Uint8List(0);

  final String controlType;
  final Uint8List prevControlHash;
  final Uint8List certBytes;
  final Uint8List rootSig;

  Map<String, Object?> toJson() => {
        'type': controlType,
        'prev_control_hash': _hex(prevControlHash),
        'cert': base64Encode(certBytes),
        'root_sig': base64Encode(rootSig),
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static ControlPayload decode(Uint8List payload) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(payload));
    } on FormatException {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'control payload is not UTF-8 JSON',
      );
    }
    if (raw is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'control payload must be a JSON object',
      );
    }

    final controlType = raw['type'];
    if (controlType is! String || controlType.isEmpty) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'control payload type must be a non-empty string',
      );
    }
    final prevHashHex = raw['prev_control_hash'];
    if (prevHashHex is! String || !_hex64Pattern.hasMatch(prevHashHex)) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'prev_control_hash must be 64 lowercase hex characters',
      );
    }
    final prevControlHash = _fromHex(prevHashHex);

    if (controlType != controlTypeMemberRegister) {
      // Nothing beyond the self-identifying fields is defined for a type this
      // build does not serve; refusing it is the caller's job.
      return ControlPayload(
        controlType: controlType,
        prevControlHash: prevControlHash,
      );
    }

    final rootSig = _requireBase64(raw['root_sig'], 'root_sig');
    if (rootSig.length != signatureLengthBytes) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'root_sig must be $signatureLengthBytes bytes',
      );
    }
    final certBytes = _requireBase64(raw['cert'], 'cert');
    if (certBytes.isEmpty) {
      throw const SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        'cert must not be empty',
      );
    }
    return ControlPayload(
      controlType: controlType,
      prevControlHash: prevControlHash,
      certBytes: certBytes,
      rootSig: rootSig,
    );
  }

  /// Parse the certificate blob.
  ///
  /// Only meaningful *after* [verifyRegistrationCertificate] has checked Root's
  /// signature over the literal bytes — parsing first would be reading an
  /// unauthenticated document.
  RegistrationCertificate certificate() => RegistrationCertificate.decode(certBytes);

  void requireServedType() {
    if (!servedControlTypes.contains(controlType)) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedControlType,
        'control type "$controlType" is not served',
      );
    }
  }
}

Uint8List registrationSigningInput(Uint8List certBytes) =>
    domainSeparated(signingDomainMemberRegisterV1, [certBytes]);

/// Throws [SyncRejection] unless Root signed exactly these certificate bytes.
Future<void> verifyRegistrationCertificate(
  Uint8List certBytes,
  Uint8List rootSig,
  Uint8List rootPk,
) async {
  final ok = await verifyDomainSeparated(
    registrationSigningInput(certBytes),
    rootSig,
    rootPk,
  );
  if (!ok) {
    throw const SyncRejection(
      SyncRejectionReason.badRootSignature,
      'Root signature over the certificate does not verify',
    );
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}
