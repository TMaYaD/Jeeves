/// The `op_class = 2` control payload format and its four certificates.
///
/// A deliberate mirror of `backend/app/sync/control_payload.py`, pinned by
/// `spec/sync/envelope_v1_vectors.json`'s `control_vectors`. Control ops are the
/// one part of the log that is *not* opaque: they are unencrypted precisely so
/// that whoever holds the bytes — server or peer — can check that a Member was
/// registered by Root, and that a role was granted by somebody entitled to grant
/// it, before honouring anything (ADR-0028, F2).
///
/// Four served types, all sharing the same two mandatory fields:
///
/// ```
/// {"type": "member_register",   "prev_control_hash": "<hex64>",
///  "cert": "<base64>", "root_sig": "<base64>"}
/// {"type": "workspace_genesis", "prev_control_hash": "<hex64>",
///  "cert": "<base64>", "root_sig": "<base64>"}
/// {"type": "grant",  "prev_control_hash": "<hex64>",
///  "cert": "<base64>", "granter_sig": "<base64>", "granter": "root"|"<uuid>"}
/// {"type": "revoke", "prev_control_hash": "<hex64>",
///  "cert": "<base64>", "revoker_sig": "<base64>", "revoker": "root"|"<uuid>"}
/// ```
///
/// The chain link is over the predecessor's **payload bytes** — the unframed
/// payload `parseBody` returns — not the envelope and not a re-serialization.
/// The price of hashing bare bytes is that nothing outside them says what they
/// are, so **every control payload must be self-identifying: `type` is
/// mandatory in every control type, for ever.**
///
/// An **all-zero `prev_control_hash` is genesis-only** (ADR-0031), both ways: a
/// `member_register`, grant or revoke carrying one is refused even by a receiver
/// whose control state is empty — so a fresh device served a truncated history
/// always detects it — and a genesis carrying anything else is refused too,
/// because genesis is by definition the Workspace's first control op.
///
/// Every certificate is signed bytes, never re-serialized JSON: a verifier checks
/// the signature over the literal decoded blob and only then parses it.
///
/// **The domain string is the version.** No cert JSON carries a version field;
/// any field addition ships under a new signing domain, so old certs stay
/// verifiable and a downgrade is a signature failure rather than a parsing
/// ambiguity.
///
/// **Authority ceilings.** A Grant whose `role` is `owner` may only be minted
/// with `granter == "root"`, and only be revoked with `revoker == "root"`. The
/// pairing is deliberately symmetric — see ADR-0031 for why an owner-mints-owner
/// rule would favour an attacker. The mint half is a pure document invariant and
/// is enforced here at decode; the revoke half needs the target Grant's role,
/// which is receiver state, so it lives in the authorization stage.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'envelope.dart';
import 'hlc.dart';

const String controlTypeMemberRegister = 'member_register';
const String controlTypeWorkspaceGenesis = 'workspace_genesis';
const String controlTypeGrant = 'grant';
const String controlTypeRevoke = 'revoke';

/// The control types this build serves. `rotate`/`member_key_rotate` are #554's
/// and stay fail-closed.
const Set<String> servedControlTypes = {
  controlTypeMemberRegister,
  controlTypeWorkspaceGenesis,
  controlTypeGrant,
  controlTypeRevoke,
};

/// The two types that carry their author's own registration, and are therefore
/// that author's op 1. Genesis generalises #548's `member_register` rule.
const Set<String> registeringControlTypes = {
  controlTypeMemberRegister,
  controlTypeWorkspaceGenesis,
};

/// Members that are a Device. A Service member (#557) is the same cert with a
/// different kind; the `user_preferences` Workspace refuses Grants to anything
/// that is not a Device, which is what makes "no Service ever" structural.
const String memberKindDevice = 'device';
const String memberKindService = 'service';

// --- Roles -------------------------------------------------------------------

const String roleOwner = 'owner';
const String roleParticipant = 'participant';
const String roleCompactor = 'compactor';
const String roleSuggester = 'suggester';

/// Every role a Grant may carry. An unknown role fails closed on both sides.
const List<String> knownRoles = [roleOwner, roleParticipant, roleCompactor, roleSuggester];

/// The `granter`/`revoker` value meaning "the pinned Root itself". A member id is
/// the only other legal value, and `"root"` is not a UUID, so the two cases can
/// never be confused.
const String granterRoot = 'root';

/// Which `(role, op_class)` pairs a role admits.
///
/// Rows for op classes this build does not *serve* are defined here anyway, so
/// #555 and #557 turn a class on by widening [servedOpClasses] rather than by
/// inventing a policy.
const Map<int, Set<String>> roleOpClassMatrix = {
  opClassContent: {roleOwner, roleParticipant},
  // Control, when the payload is not root-signed.
  opClassControl: {roleOwner},
  // Suggestion — defined, unserved until #557.
  opClassSuggestion: {roleOwner, roleParticipant, roleCompactor, roleSuggester},
  // Compaction and prune — defined, unserved until #555.
  opClassCompaction: {roleOwner, roleCompactor},
  opClassPrune: {roleOwner, roleCompactor},
};

/// Op classes a compaction pass must carry forward verbatim rather than fold.
///
/// Control ops are the authority record: compacting one away would delete the
/// evidence a Grant ever existed, and a prune op is itself the attestation that
/// history was removed. #555 enforces this; the predicate lives here so both
/// codecs and the vectors pin the same rule before prune exists.
const Set<int> compactionExemptOpClasses = {opClassControl, opClassPrune};

/// Whether [opClass] is never folded into a compaction op (#555).
bool isCompactionExempt(int opClass) => compactionExemptOpClasses.contains(opClass);

const int prevControlHashBytes = 32;

/// Raw X25519 public key width. Separate from the signing key per F8/F19.
const int kexPublicKeyBytes = 32;

/// Raw Ed25519 Root public key width.
const int rootPublicKeyBytes = 32;

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

/// `"root"` or a canonical member uuid — the two authorities there are.
String _requireAuthority(Object? raw, String what) {
  if (raw == granterRoot) return granterRoot;
  if (raw is! String || !isCanonicalUuid(raw)) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what must be "$granterRoot" or a canonical lowercase member UUID',
    );
  }
  return raw;
}

Map<String, dynamic> _decodeCertJson(Uint8List certBytes) {
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
  return raw;
}

Hlc _decodeHlc(Object? raw, String what) {
  try {
    return Hlc.fromJson(raw);
  } on SyncRejection catch (rejection) {
    throw SyncRejection(
      SyncRejectionReason.malformedControlPayload,
      '$what is malformed: ${rejection.message}',
    );
  }
}

/// One Member's certified public keys — the block a registration carries.
///
/// Shared verbatim by `member_register` (at the top level of its cert) and by
/// `workspace_genesis` (under `founder`), because genesis *is* the founding
/// Device's registration: the envelope's author key has to be learnable from the
/// payload itself, and there is no earlier op to learn it from (ADR-0031).
class MemberKeys {
  MemberKeys({
    required this.memberId,
    required this.signPk,
    required this.kexPk,
    this.memberKind = memberKindDevice,
  });

  final String memberId;
  final Uint8List signPk;
  final Uint8List kexPk;
  final String memberKind;

  Uint8List get signKeyId => deriveKeyId(signPk);

  /// The same derivation as the signing key id, over the KEX key — literally
  /// the same function, so the two key ids cannot drift apart. Carried
  /// explicitly so #554 can rotate either key without changing the shape.
  Uint8List get kexKeyId => deriveKeyId(kexPk);

  Map<String, Object?> toJson() => {
        'member_id': memberId,
        'member_kind': memberKind,
        'sign_pk': base64Encode(signPk),
        'sign_key_id': base64Encode(signKeyId),
        'kex_pk': base64Encode(kexPk),
        'kex_key_id': base64Encode(kexKeyId),
      };

  static MemberKeys fromJson(Object? raw, String what) {
    if (raw is! Map<String, dynamic>) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        '$what must be a JSON object',
      );
    }
    final memberKind = raw['member_kind'];
    if (memberKind is! String || memberKind.isEmpty) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        '$what member_kind must be a non-empty string',
      );
    }
    final keys = MemberKeys(
      memberId: _requireCanonicalUuid(raw['member_id'], '$what member_id'),
      signPk: _requireKey(raw['sign_pk'], '$what sign_pk', signPublicKeyBytes),
      kexPk: _requireKey(raw['kex_pk'], '$what kex_pk', kexPublicKeyBytes),
      memberKind: memberKind,
    );
    // The ids are derivations, so a claim that disagrees with the derivation is
    // a forgery attempt, not a variant spelling.
    if (!sameBytes(
      _requireKey(raw['sign_key_id'], '$what sign_key_id', authorKeyIdBytes),
      keys.signKeyId,
    )) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        '$what sign_key_id is not derived from sign_pk',
      );
    }
    if (!sameBytes(
      _requireKey(raw['kex_key_id'], '$what kex_key_id', authorKeyIdBytes),
      keys.kexKeyId,
    )) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        '$what kex_key_id is not derived from kex_pk',
      );
    }
    return keys;
  }
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

  Uint8List get kexKeyId => deriveKeyId(kexPk);

  MemberKeys get keys => MemberKeys(
        memberId: memberId,
        signPk: signPk,
        kexPk: kexPk,
        memberKind: memberKind,
      );

  Map<String, Object?> toJson() => {
        'workspace_id': workspaceId,
        ...keys.toJson(),
        'registered_at_hlc': registeredAtHlc.toJson(),
      };

  /// UTF-8 JSON. These are the bytes Root signs and a verifier hashes — never a
  /// re-serialization of the parsed form.
  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static RegistrationCertificate decode(Uint8List certBytes) {
    final raw = _decodeCertJson(certBytes);
    final keys = MemberKeys.fromJson(raw, 'cert');
    return RegistrationCertificate(
      workspaceId: _requireCanonicalUuid(raw['workspace_id'], 'cert workspace_id'),
      memberId: keys.memberId,
      signPk: keys.signPk,
      kexPk: keys.kexPk,
      registeredAtHlc: _decodeHlc(raw['registered_at_hlc'], 'cert registered_at_hlc'),
      memberKind: keys.memberKind,
    );
  }
}

/// Root's statement that a Workspace exists, and who founded it.
///
/// [rootPk] inside the signed bytes gives every later verifier a log-internal
/// cross-check against the Root it pinned, and makes the genesis self-describing
/// for a future shared-Workspace reader. [founder] *is* a registration: the
/// founding Device authors no separate `member_register` (ADR-0031). Per F14(d)
/// the founder is merely the first owner — revoking it later invalidates nothing.
class GenesisCertificate {
  GenesisCertificate({
    required this.workspaceId,
    required this.rootPk,
    required this.founder,
    required this.createdAtHlc,
  });

  final String workspaceId;
  final Uint8List rootPk;
  final MemberKeys founder;
  final Hlc createdAtHlc;

  Map<String, Object?> toJson() => {
        'workspace_id': workspaceId,
        'root_pk': base64Encode(rootPk),
        'founder': founder.toJson(),
        'created_at_hlc': createdAtHlc.toJson(),
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static GenesisCertificate decode(Uint8List certBytes) {
    final raw = _decodeCertJson(certBytes);
    return GenesisCertificate(
      workspaceId: _requireCanonicalUuid(raw['workspace_id'], 'cert workspace_id'),
      rootPk: _requireKey(raw['root_pk'], 'cert root_pk', rootPublicKeyBytes),
      founder: MemberKeys.fromJson(raw['founder'], 'cert founder'),
      createdAtHlc: _decodeHlc(raw['created_at_hlc'], 'cert created_at_hlc'),
    );
  }

  /// The founder's registration, as the directory learns it.
  ///
  /// Genesis is the founding Device's `member_register`; this is the same fact in
  /// the shape every other member's arrives in.
  RegistrationCertificate asRegistration() => RegistrationCertificate(
        workspaceId: workspaceId,
        memberId: founder.memberId,
        signPk: founder.signPk,
        kexPk: founder.kexPk,
        registeredAtHlc: createdAtHlc,
        memberKind: founder.memberKind,
      );
}

/// One authority fact: this Member holds this role in this Workspace.
///
/// Grant-granular by construction: a Member may hold several, and a Revoke names
/// one [grantId] rather than a member (F19 keeps member-revocation and
/// grant-revocation distinct). No key material — the Grant/KeyWrap split is
/// physical, which is what lets #554 land rotation without touching this shape.
class GrantCertificate {
  GrantCertificate({
    required this.workspaceId,
    required this.grantId,
    required this.memberId,
    required this.role,
    required this.granter,
    required this.grantedAtHlc,
  });

  final String workspaceId;
  final String grantId;
  final String memberId;
  final String role;
  final String granter;
  final Hlc grantedAtHlc;

  Map<String, Object?> toJson() => {
        'workspace_id': workspaceId,
        'grant_id': grantId,
        'member_id': memberId,
        'role': role,
        'granter': granter,
        'granted_at_hlc': grantedAtHlc.toJson(),
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static GrantCertificate decode(Uint8List certBytes) {
    final raw = _decodeCertJson(certBytes);
    final role = raw['role'];
    if (role is! String || !knownRoles.contains(role)) {
      throw SyncRejection(
        SyncRejectionReason.unknownRole,
        'grant role "$role" is not one of $knownRoles',
      );
    }
    final granter = _requireAuthority(raw['granter'], 'cert granter');
    if (role == roleOwner && granter != granterRoot) {
      // The mint half of the owner ceiling, and a **pure document invariant**: a
      // certificate claiming `role: owner` under any granter but Root is not a
      // Grant a verifier could ever honour, so it is refused at decode rather
      // than deeper in whoever happens to be holding it. ADR-0031 records why
      // the ceiling is symmetric with revocation. (The *revoke* half needs the
      // target Grant's role, which is receiver state and not in these bytes.)
      throw SyncRejection(
        SyncRejectionReason.ownerGrantRequiresRoot,
        'an owner Grant may only be minted with granter "$granterRoot", not "$granter"',
      );
    }
    return GrantCertificate(
      workspaceId: _requireCanonicalUuid(raw['workspace_id'], 'cert workspace_id'),
      grantId: _requireCanonicalUuid(raw['grant_id'], 'cert grant_id'),
      memberId: _requireCanonicalUuid(raw['member_id'], 'cert member_id'),
      role: role,
      granter: granter,
      grantedAtHlc: _decodeHlc(raw['granted_at_hlc'], 'cert granted_at_hlc'),
    );
  }
}

/// The unmaking of one Grant, named by [grantId].
class RevokeCertificate {
  RevokeCertificate({
    required this.workspaceId,
    required this.revokeId,
    required this.grantId,
    required this.revoker,
    required this.revokedAtHlc,
  });

  final String workspaceId;
  final String revokeId;
  final String grantId;
  final String revoker;
  final Hlc revokedAtHlc;

  Map<String, Object?> toJson() => {
        'workspace_id': workspaceId,
        'revoke_id': revokeId,
        'grant_id': grantId,
        'revoker': revoker,
        'revoked_at_hlc': revokedAtHlc.toJson(),
      };

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static RevokeCertificate decode(Uint8List certBytes) {
    final raw = _decodeCertJson(certBytes);
    return RevokeCertificate(
      workspaceId: _requireCanonicalUuid(raw['workspace_id'], 'cert workspace_id'),
      revokeId: _requireCanonicalUuid(raw['revoke_id'], 'cert revoke_id'),
      grantId: _requireCanonicalUuid(raw['grant_id'], 'cert grant_id'),
      revoker: _requireAuthority(raw['revoker'], 'cert revoker'),
      revokedAtHlc: _decodeHlc(raw['revoked_at_hlc'], 'cert revoked_at_hlc'),
    );
  }
}

/// `controlType -> (signature field, authority field or null)`.
const Map<String, (String, String?)> _signatureFields = {
  controlTypeMemberRegister: ('root_sig', null),
  controlTypeWorkspaceGenesis: ('root_sig', null),
  controlTypeGrant: ('granter_sig', 'granter'),
  controlTypeRevoke: ('revoker_sig', 'revoker'),
};

/// The types whose signer is Root and nobody else.
const Set<String> _rootOnlyControlTypes = {
  controlTypeMemberRegister,
  controlTypeWorkspaceGenesis,
};

/// A parsed control op body.
///
/// One class for four types, because the two mandatory fields — `type` and
/// `prev_control_hash` — are the whole of what a receiver may read before it
/// knows which type it is holding. [signature] carries whichever of
/// `root_sig`/`granter_sig`/`revoker_sig` the type names, and [authority]
/// carries `granter`/`revoker` (always `root` for the two Root-only types,
/// whose authority is Root by definition).
class ControlPayload {
  ControlPayload({
    required this.controlType,
    required this.prevControlHash,
    Uint8List? certBytes,
    Uint8List? signature,
    String? authority,
  })  : certBytes = certBytes ?? Uint8List(0),
        signature = signature ?? Uint8List(0),
        authority = authority ??
            (_rootOnlyControlTypes.contains(controlType) ? granterRoot : '');

  final String controlType;
  final Uint8List prevControlHash;
  final Uint8List certBytes;
  final Uint8List signature;
  final String authority;

  /// The Root signature, for the two types whose signer is always Root.
  Uint8List get rootSig => signature;

  /// Whether this payload's authority is the pinned Root itself.
  ///
  /// The server's control-op admission rule reads this: a Root-signed control
  /// payload lands regardless of the author's Grants, which is how the
  /// register-plus-grant batch of an ungranted device gets in at all.
  bool get isRootSigned =>
      _rootOnlyControlTypes.contains(controlType) || authority == granterRoot;

  Map<String, Object?> toJson() {
    final fields = _signatureFields[controlType] ?? ('root_sig', null);
    return {
      'type': controlType,
      'prev_control_hash': _hex(prevControlHash),
      'cert': base64Encode(certBytes),
      fields.$1: base64Encode(signature),
      if (fields.$2 != null) fields.$2!: authority,
    };
  }

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

    final fields = _signatureFields[controlType];
    if (fields == null) {
      // Nothing beyond the self-identifying fields is defined for a type this
      // build does not serve; refusing it is the caller's job.
      return ControlPayload(
        controlType: controlType,
        prevControlHash: prevControlHash,
      );
    }

    final signature = _requireBase64(raw[fields.$1], fields.$1);
    if (signature.length != signatureLengthBytes) {
      throw SyncRejection(
        SyncRejectionReason.malformedControlPayload,
        '${fields.$1} must be $signatureLengthBytes bytes',
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
      signature: signature,
      authority: fields.$2 == null
          ? granterRoot
          : _requireAuthority(raw[fields.$2!], fields.$2!),
    );
  }

  /// Parse a `member_register` certificate blob.
  ///
  /// Only meaningful *after* [verifyRegistrationCertificate] has checked Root's
  /// signature over the literal bytes — parsing first would be reading an
  /// unauthenticated document. The same applies to every sibling below.
  RegistrationCertificate certificate() => RegistrationCertificate.decode(certBytes);

  GenesisCertificate genesisCertificate() => GenesisCertificate.decode(certBytes);

  GrantCertificate grantCertificate() => GrantCertificate.decode(certBytes);

  RevokeCertificate revokeCertificate() => RevokeCertificate.decode(certBytes);

  void requireServedType() {
    if (!servedControlTypes.contains(controlType)) {
      throw SyncRejection(
        SyncRejectionReason.unsupportedControlType,
        'control type "$controlType" is not served',
      );
    }
  }

  /// The genesis-only zero-link rule, both ways, as a payload-level check.
  ///
  /// Stateless, so a receiver can apply it before it knows anything about its own
  /// control state. Only a `workspace_genesis` may carry a zero link — so every
  /// other type carrying one is a truncated-history claim — and a genesis may
  /// carry *nothing else*, because it is by definition the Workspace's first
  /// control op.
  void requireChainLinkShape() {
    final isGenesis = controlType == controlTypeWorkspaceGenesis;
    final isZero = sameBytes(prevControlHash, zeroPrevControlHash);
    if (isZero && !isGenesis) {
      throw SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'an all-zero prev_control_hash is genesis-only; $controlType must name '
        'the control op before it',
      );
    }
    if (isGenesis && !isZero) {
      throw const SyncRejection(
        SyncRejectionReason.controlChainBreak,
        'a workspace_genesis is the Workspace\'s first control op, so it must '
        'carry the all-zero prev_control_hash',
      );
    }
  }
}

// --- Signing and verification ------------------------------------------------

Uint8List registrationSigningInput(Uint8List certBytes) =>
    domainSeparated(signingDomainMemberRegisterV1, [certBytes]);

Uint8List genesisSigningInput(Uint8List certBytes) =>
    domainSeparated(signingDomainWorkspaceGenesisV1, [certBytes]);

Uint8List grantSigningInput(Uint8List certBytes) =>
    domainSeparated(signingDomainGrantV1, [certBytes]);

Uint8List revokeSigningInput(Uint8List certBytes) =>
    domainSeparated(signingDomainRevokeV1, [certBytes]);

Future<void> _verifyOrThrow(
  Uint8List signingInput,
  Uint8List signature,
  Uint8List publicKey,
  SyncRejectionReason reason,
  String message,
) async {
  if (!await verifyDomainSeparated(signingInput, signature, publicKey)) {
    throw SyncRejection(reason, message);
  }
}

/// Throws [SyncRejection] unless Root signed exactly these certificate bytes.
Future<void> verifyRegistrationCertificate(
  Uint8List certBytes,
  Uint8List rootSig,
  Uint8List rootPk,
) =>
    _verifyOrThrow(
      registrationSigningInput(certBytes),
      rootSig,
      rootPk,
      SyncRejectionReason.badRootSignature,
      'Root signature over the certificate does not verify',
    );

Future<void> verifyGenesisCertificate(
  Uint8List certBytes,
  Uint8List rootSig,
  Uint8List rootPk,
) =>
    _verifyOrThrow(
      genesisSigningInput(certBytes),
      rootSig,
      rootPk,
      SyncRejectionReason.badRootSignature,
      'Root signature over the genesis certificate does not verify',
    );

Future<void> verifyGrantCertificate(
  Uint8List certBytes,
  Uint8List granterSig,
  Uint8List granterPk,
) =>
    _verifyOrThrow(
      grantSigningInput(certBytes),
      granterSig,
      granterPk,
      SyncRejectionReason.badGrantSignature,
      "the granter's signature over the Grant does not verify",
    );

Future<void> verifyRevokeCertificate(
  Uint8List certBytes,
  Uint8List revokerSig,
  Uint8List revokerPk,
) =>
    _verifyOrThrow(
      revokeSigningInput(certBytes),
      revokerSig,
      revokerPk,
      SyncRejectionReason.badRevokeSignature,
      "the revoker's signature over the Revoke does not verify",
    );

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16);
  }
  return bytes;
}
