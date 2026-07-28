/// This Device's keys, and the directory of keys it will verify against.
///
/// A Device holds two keypairs (review F8/F19): Ed25519 for signing envelopes
/// and challenges, X25519 for key agreement once #554's KeyWraps exist. They
/// are separate because a rotation of one should not force a rotation of the
/// other, and because using one key for two algorithms is how protocols get
/// cross-protocol attacks.
///
/// The directory is the heart of ADR-0028's trust model, and it is
/// **chain-gated**: an entry exists only for this device's own identity and for
/// Members whose Root-signed MemberRegister this device verified itself. The
/// server's `GET /members` registry is a bootstrap hint and is never read here.
/// That is what makes "ops from a Member not chained to Root are rejected by
/// clients regardless of what the server serves" true rather than aspirational.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import 'control_payload.dart';
import 'envelope.dart';
import 'hlc.dart';

const Uuid _uuid = Uuid();

/// This device's Member id and its two keypairs.
class MemberIdentity {
  MemberIdentity._(
    this.memberId,
    this.signer,
    this._kexKeyPair,
    this.kexSeed,
    this.kexPk,
  );

  /// [signSeed]/[kexSeed] make a device's keys deterministic, which the harness
  /// relies on to re-open a "restarted" device with the same identity.
  static Future<MemberIdentity> generate({
    String? memberId,
    Uint8List? signSeed,
    Uint8List? kexSeed,
    Random? random,
  }) async {
    final entropy = random ?? Random.secure();
    final signer = await EnvelopeSigner.fromSeed(
      signSeed ?? _randomSeed(entropy),
    );
    final resolvedKexSeed = kexSeed ?? _randomSeed(entropy);
    final kexKeyPair = await X25519().newKeyPairFromSeed(resolvedKexSeed);
    final kexPublicKey = await kexKeyPair.extractPublicKey();
    return MemberIdentity._(
      memberId ?? _uuid.v4(),
      signer,
      kexKeyPair,
      Uint8List.fromList(resolvedKexSeed),
      Uint8List.fromList(kexPublicKey.bytes),
    );
  }

  final String memberId;
  final EnvelopeSigner signer;
  final SimpleKeyPair _kexKeyPair;

  /// The 32 raw X25519 seed bytes, for `DeviceKeyStore`.
  final Uint8List kexSeed;

  /// The raw 32-byte X25519 public key. Registered and certified now; read by
  /// nothing until #554.
  final Uint8List kexPk;

  String get memberIdHex => memberIdToHex(memberId);

  Uint8List get signPk => signer.signPublicKey;

  /// Computed locally with the same derivation the server applies, so the
  /// header's `author_key_id` and the certificate's agree without a round-trip.
  Uint8List get keyId => signer.keyId;

  /// The key-agreement half, for #554. Held here so the seam exists before the
  /// feature does and the cert never has to grow a field to carry it.
  SimpleKeyPair get kexKeyPair => _kexKeyPair;

  /// Prove possession of the signing key for a transport challenge.
  ///
  /// The member id is inside the signed bytes, so a captured signature cannot
  /// be replayed into another Member's challenge slot.
  Future<Uint8List> signTransportChallenge(Uint8List nonce) => signer.signBytes(
        domainSeparated(
          signingDomainAuthChallengeV1,
          [uuidToBytes(memberId), nonce],
        ),
      );

  /// The certificate Root signs to register this device.
  RegistrationCertificate certificateFor({
    required String workspaceId,
    required Hlc registeredAtHlc,
  }) =>
      RegistrationCertificate(
        workspaceId: workspaceId,
        memberId: memberId,
        signPk: signPk,
        kexPk: kexPk,
        registeredAtHlc: registeredAtHlc,
      );

  static Uint8List _randomSeed(Random random) => Uint8List.fromList(
        List<int>.generate(signPublicKeyBytes, (_) => random.nextInt(256)),
      );
}

/// The verifying keys this device will accept an op from.
///
/// `author_key_id` selects *which* of an author's keys verifies an op, so a key
/// rotation (#549) is a new entry rather than an overwrite. An op naming a slot
/// this directory has never learned is refused, never guessed at — and the only
/// way to learn one is a MemberRegister that passed the full verification in
/// `SyncClient`.
class MemberDirectory {
  final Map<String, Uint8List> _keys = {};
  final Set<String> _chainedMembers = {};

  /// The `member_kind` each chained Member's certificate asserted.
  ///
  /// A *signed* fact, so it is learned the same way keys are — never from the
  /// server's registry. The `user_preferences` Workspace reads it to refuse Grants
  /// to anything that is not a Device.
  final Map<String, String> _kinds = {};

  static String _slot(String memberId, Uint8List keyId) => '$memberId/${_hex(keyId)}';

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  /// This device's own keys. Trusted because they never left this device — the
  /// one entry that does not come from the log.
  void rememberSelf(MemberIdentity identity) {
    _keys[_slot(identity.memberId, identity.keyId)] = identity.signPk;
    _chainedMembers.add(identity.memberId);
    // This device is a Device. The one kind that does not come from the log,
    // for the same reason its keys do not.
    _kinds[identity.memberId] = memberKindDevice;
  }

  /// Learn a Member's key from a certificate that has already been verified.
  ///
  /// Deliberately takes the parsed certificate rather than a registry record:
  /// there is no way to call this with something the server merely asserted.
  void rememberChained(RegistrationCertificate certificate) {
    _keys[_slot(certificate.memberId, certificate.signKeyId)] = certificate.signPk;
    _chainedMembers.add(certificate.memberId);
    _kinds[certificate.memberId] = certificate.memberKind;
  }

  bool isChained(String memberId) => _chainedMembers.contains(memberId);

  /// The kind a verified certificate asserted for [memberId], or null for a
  /// member this device has never chained. Null is the fail-closed answer: a
  /// caller that cannot resolve a kind must refuse rather than assume one.
  String? kindOf(String memberId) => _kinds[memberId];

  /// The public key for this author and key id, or a fail-closed refusal.
  Uint8List publicKeyFor(String memberId, Uint8List keyId) {
    final key = _keys[_slot(memberId, keyId)];
    if (key == null) {
      throw SyncRejection(
        SyncRejectionReason.memberNotChainedToRoot,
        'no Root-signed registration for member $memberId key ${_hex(keyId)}',
      );
    }
    return key;
  }
}
