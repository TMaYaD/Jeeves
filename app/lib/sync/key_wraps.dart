/// The KeyWrap formats: how a Workspace epoch key reaches a Member, and the escrow.
///
/// A deliberate mirror of `backend/app/sync/key_wraps.py`, pinned byte-for-byte by
/// `spec/sync/envelope_v1_vectors.json`'s `keywrap_vectors`. Two wrap flavours,
/// both carrying the same 32-byte plaintext — a Workspace content key
/// `K_{w,epoch}` — and neither of them ever openable by the server (ADR-0037).
///
/// **KeyWrap**, one per `(Member, epoch)`. A sealed-box-equivalent to the Member's
/// registered X25519 `kex_pk`. This is the delivery of a Grant's entitlement: a
/// Grant carries no key material (F19), a KeyWrap carries no authority.
///
/// ```
/// info = "jeeves/keywrap/v1" || epk 32B || workspace_id 16B
///     || epoch u32 BE || member_id 16B || kex_key_id 8B          (93 bytes)
///
/// wrap = epk 32B || nonce 24B || XChaCha20-Poly1305(
///            key   = HKDF-SHA256(ikm = X25519(esk, kex_pk), salt = "", info),
///            nonce, aad = info, plaintext = K 32B)               (104 bytes)
/// ```
///
/// **Escrow wrap**, one per `(Workspace, epoch)`. A plain symmetric wrap under the
/// `master_wrap_key` the recovery escrow has carried since #553.
///
/// ```
/// info        = "jeeves/epoch-key-escrow/v1" || workspace_id 16B
///            || epoch u32 BE                                    (42 bytes)
/// escrow_wrap = nonce 24B || XChaCha20-Poly1305(
///                   master_wrap_key, nonce, aad = info, plaintext = K 32B)
/// ```
///
/// The escrow wrap is what makes a fresh device's bootstrap work with **no live
/// second device**: the passphrase yields `master_wrap_key`, which opens every
/// historical epoch key, which decrypts the whole history. That is the same "no
/// second device online, ever" invariant enrolment already runs on.
///
/// Three properties the `info`/AAD binding buys, and why each field is in there:
///
/// * `epk` — HPKE discipline: the encapsulated key belongs in the key schedule, so
///   an attacker cannot re-point a captured wrap at a different ephemeral share.
/// * `workspace_id` and `epoch` — a wrap cannot be replayed into another Workspace
///   or another epoch, so an honest-but-confused server cannot deliver yesterday's
///   key as today's.
/// * `member_id` and `kex_key_id` — a wrap cannot be handed to a different Member,
///   nor to a different key of the same Member.
///
/// Because `info` is both the HKDF info *and* the AEAD AAD, a mismatch on any of
/// them is an authentication failure rather than a silent decryption to garbage.
///
/// **The digest is what stops the server curating the wrap set.** A `rotate`
/// control op commits to `keywrap_digest` before any wrap is uploaded, and
/// `PUT /w/{w}/keywraps` refuses a set that does not hash to it — so the server can
/// neither add a wrap nor omit one. The escrow wrap is inside the digest for the
/// same reason.
///
/// ```
/// keywrap_digest = SHA-256(
///     "jeeves/keywrap-digest/v1" || epoch u32 BE || member_wrap_count u32 BE
///     || for each (member_id, kex_key_id, wrap) sorted by (member_id, kex_key_id):
///            member_id 16B || kex_key_id 8B || SHA-256(wrap) 32B
///     || SHA-256(escrow_wrap) 32B)
/// ```
///
/// Sorted, so the digest is a property of the *set* and not of an upload order the
/// server could shuffle.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'envelope.dart';

/// Every use of every key is domain-separated (review F7), the wraps included.
const String keyWrapInfoDomain = 'jeeves/keywrap/v1';
const String epochKeyEscrowInfoDomain = 'jeeves/epoch-key-escrow/v1';
const String keyWrapDigestDomain = 'jeeves/keywrap-digest/v1';

/// The ephemeral X25519 share a KeyWrap carries, so it needs no prior state.
const int ephemeralPublicKeyBytes = 32;
const int wrapNonceBytes = 24;
const int keyWrapDigestBytes = 32;

/// Fixed widths, so a wrap of the wrong length is refused before any crypto runs.
const int keyWrapBytes =
    ephemeralPublicKeyBytes + wrapNonceBytes + workspaceKeyBytes + aeadTagBytes;
const int epochKeyEscrowWrapBytes = wrapNonceBytes + workspaceKeyBytes + aeadTagBytes;

/// A `key_epoch` is a header `u32`, so this is the ceiling everywhere.
const int maxKeyEpoch = 0xFFFFFFFF;

final Cipher _wrapCipher = Xchacha20.poly1305Aead();
final X25519 _kex = X25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: workspaceKeyBytes);

/// One Member's wrap, as the ceremony builds it and the digest consumes it.
class MemberKeyWrap {
  const MemberKeyWrap({
    required this.memberId,
    required this.kexKeyId,
    required this.wrap,
  });

  final String memberId;

  /// Which of the Member's KEX keys this wrap is sealed to. Carried explicitly so
  /// a key rotation is a new wrap rather than an ambiguous overwrite.
  final Uint8List kexKeyId;
  final Uint8List wrap;
}

Uint8List _epochBytes(int epoch) {
  if (epoch < 0 || epoch > maxKeyEpoch) {
    throw ArgumentError('key_epoch $epoch does not fit the header\'s u32');
  }
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setUint32(0, epoch, Endian.big);
  return bytes;
}

/// The HKDF `info` and the AEAD AAD — deliberately the same bytes.
Uint8List keyWrapInfo({
  required Uint8List ephemeralPublicKey,
  required String workspaceId,
  required int epoch,
  required String memberId,
  required Uint8List kexKeyId,
}) {
  if (ephemeralPublicKey.length != ephemeralPublicKeyBytes) {
    throw ArgumentError('epk must be $ephemeralPublicKeyBytes bytes');
  }
  if (kexKeyId.length != authorKeyIdBytes) {
    throw ArgumentError('kex_key_id must be $authorKeyIdBytes bytes');
  }
  return domainSeparated(keyWrapInfoDomain, [
    ephemeralPublicKey,
    uuidToBytes(workspaceId),
    _epochBytes(epoch),
    uuidToBytes(memberId),
    kexKeyId,
  ]);
}

Uint8List epochKeyEscrowInfo({required String workspaceId, required int epoch}) =>
    domainSeparated(epochKeyEscrowInfoDomain, [
      uuidToBytes(workspaceId),
      _epochBytes(epoch),
    ]);

/// Seal [workspaceKey] to [kexPk] under a caller-chosen ephemeral scalar and nonce.
///
/// The deterministic half, mirroring `wrap_epoch_key_for_member` in the Python
/// module exactly: the golden vectors pin an ephemeral seed and a nonce, and both
/// codecs must reproduce the same 104 bytes from them. Production goes through
/// [wrapEpochKeyForMember], which draws both.
Future<Uint8List> sealEpochKeyForMember({
  required Uint8List workspaceKey,
  required Uint8List kexPk,
  required String workspaceId,
  required int epoch,
  required String memberId,
  required Uint8List kexKeyId,
  required Uint8List ephemeralSeed,
  required Uint8List nonce,
}) async {
  if (workspaceKey.length != workspaceKeyBytes) {
    throw ArgumentError('workspace key must be $workspaceKeyBytes bytes');
  }
  if (kexPk.length != ephemeralPublicKeyBytes) {
    throw ArgumentError('kex_pk must be $ephemeralPublicKeyBytes bytes');
  }
  if (nonce.length != wrapNonceBytes) {
    throw ArgumentError('nonce must be $wrapNonceBytes bytes');
  }
  final ephemeral = await _kex.newKeyPairFromSeed(ephemeralSeed);
  final epk = Uint8List.fromList((await ephemeral.extractPublicKey()).bytes);
  final info = keyWrapInfo(
    ephemeralPublicKey: epk,
    workspaceId: workspaceId,
    epoch: epoch,
    memberId: memberId,
    kexKeyId: kexKeyId,
  );
  final box = await _wrapCipher.encrypt(
    workspaceKey,
    secretKey: await _wrapKey(
      keyPair: ephemeral,
      peerPublicKey: kexPk,
      info: info,
    ),
    nonce: nonce,
    aad: info,
  );
  return (BytesBuilder(copy: false)
        ..add(epk)
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .toBytes();
}

/// [sealEpochKeyForMember] with the entropy drawn rather than supplied.
///
/// [random] is the seam the harness uses; production passes nothing and gets
/// `Random.secure()`, one fresh ephemeral keypair per wrap. It draws the ephemeral
/// scalar *and* the nonce, which is the whole of this construction's entropy — the
/// `wrapEscrowBlob({Random? random})` pattern.
Future<Uint8List> wrapEpochKeyForMember({
  required Uint8List workspaceKey,
  required Uint8List kexPk,
  required String workspaceId,
  required int epoch,
  required String memberId,
  required Uint8List kexKeyId,
  Random? random,
}) async {
  final entropy = random ?? Random.secure();
  return sealEpochKeyForMember(
    workspaceKey: workspaceKey,
    kexPk: kexPk,
    workspaceId: workspaceId,
    epoch: epoch,
    memberId: memberId,
    kexKeyId: kexKeyId,
    ephemeralSeed: randomBytes(entropy, keyWrapSeedBytes),
    nonce: randomBytes(entropy, wrapNonceBytes),
  );
}

/// Open a KeyWrap, or refuse it.
///
/// The `info` is *reconstructed from this device's own idea* of which Workspace,
/// epoch, member and key the wrap is for — never read out of the wrap — so a wrap
/// delivered into the wrong slot fails to authenticate instead of opening. The only
/// thing taken from the wrap itself is `epk`, which is bound into that same `info`
/// and therefore cannot be swapped either.
Future<Uint8List> unwrapEpochKeyForMember({
  required Uint8List wrap,
  required SimpleKeyPair kexKeyPair,
  required String workspaceId,
  required int epoch,
  required String memberId,
  required Uint8List kexKeyId,
}) async {
  if (wrap.length != keyWrapBytes) {
    throw SyncRejection(
      SyncRejectionReason.malformedKeyWrap,
      'a keywrap is $keyWrapBytes bytes, got ${wrap.length}',
    );
  }
  final epk = Uint8List.sublistView(wrap, 0, ephemeralPublicKeyBytes);
  final nonce = Uint8List.sublistView(
    wrap,
    ephemeralPublicKeyBytes,
    ephemeralPublicKeyBytes + wrapNonceBytes,
  );
  final sealed = Uint8List.sublistView(wrap, ephemeralPublicKeyBytes + wrapNonceBytes);
  final info = keyWrapInfo(
    ephemeralPublicKey: Uint8List.fromList(epk),
    workspaceId: workspaceId,
    epoch: epoch,
    memberId: memberId,
    kexKeyId: kexKeyId,
  );
  final split = sealed.length - aeadTagBytes;
  try {
    return Uint8List.fromList(
      await _wrapCipher.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, split),
          nonce: nonce,
          mac: Mac(Uint8List.sublistView(sealed, split)),
        ),
        secretKey: await _wrapKey(
          keyPair: kexKeyPair,
          peerPublicKey: Uint8List.fromList(epk),
          info: info,
        ),
        aad: info,
      ),
    );
  } on SecretBoxAuthenticationError catch (error) {
    throw SyncRejection(
      SyncRejectionReason.aeadFailure,
      'the keywrap did not authenticate for this member slot: $error',
    );
  }
}

/// Wrap [workspaceKey] under the escrowed [masterWrapKey], nonce supplied.
Future<Uint8List> sealEpochKeyForEscrow({
  required Uint8List workspaceKey,
  required Uint8List masterWrapKey,
  required String workspaceId,
  required int epoch,
  required Uint8List nonce,
}) async {
  if (workspaceKey.length != workspaceKeyBytes) {
    throw ArgumentError('workspace key must be $workspaceKeyBytes bytes');
  }
  if (masterWrapKey.length != workspaceKeyBytes) {
    throw ArgumentError('master wrap key must be $workspaceKeyBytes bytes');
  }
  if (nonce.length != wrapNonceBytes) {
    throw ArgumentError('nonce must be $wrapNonceBytes bytes');
  }
  final info = epochKeyEscrowInfo(workspaceId: workspaceId, epoch: epoch);
  final box = await _wrapCipher.encrypt(
    workspaceKey,
    secretKey: SecretKey(masterWrapKey),
    nonce: nonce,
    aad: info,
  );
  return (BytesBuilder(copy: false)
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .toBytes();
}

/// [sealEpochKeyForEscrow] with the nonce drawn rather than supplied.
Future<Uint8List> wrapEpochKeyForEscrow({
  required Uint8List workspaceKey,
  required Uint8List masterWrapKey,
  required String workspaceId,
  required int epoch,
  Random? random,
}) =>
    sealEpochKeyForEscrow(
      workspaceKey: workspaceKey,
      masterWrapKey: masterWrapKey,
      workspaceId: workspaceId,
      epoch: epoch,
      nonce: randomBytes(random ?? Random.secure(), wrapNonceBytes),
    );

Future<Uint8List> unwrapEpochKeyFromEscrow({
  required Uint8List escrowWrap,
  required Uint8List masterWrapKey,
  required String workspaceId,
  required int epoch,
}) async {
  if (escrowWrap.length != epochKeyEscrowWrapBytes) {
    throw SyncRejection(
      SyncRejectionReason.malformedKeyWrap,
      'an escrow wrap is $epochKeyEscrowWrapBytes bytes, got ${escrowWrap.length}',
    );
  }
  final nonce = Uint8List.sublistView(escrowWrap, 0, wrapNonceBytes);
  final sealed = Uint8List.sublistView(escrowWrap, wrapNonceBytes);
  final split = sealed.length - aeadTagBytes;
  try {
    return Uint8List.fromList(
      await _wrapCipher.decrypt(
        SecretBox(
          Uint8List.sublistView(sealed, 0, split),
          nonce: nonce,
          mac: Mac(Uint8List.sublistView(sealed, split)),
        ),
        secretKey: SecretKey(masterWrapKey),
        aad: epochKeyEscrowInfo(workspaceId: workspaceId, epoch: epoch),
      ),
    );
  } on SecretBoxAuthenticationError catch (error) {
    throw SyncRejection(
      SyncRejectionReason.aeadFailure,
      'the epoch-key escrow wrap did not authenticate under the master wrap '
      'key: $error',
    );
  }
}

/// The commitment a `rotate` op carries, over the whole wrap set.
///
/// Sorted here rather than by the caller, so the digest is a property of the set
/// and not of an upload order the server could shuffle — and computed identically
/// on the client that commits to it and the server that checks it.
Uint8List keyWrapDigest({
  required int epoch,
  required List<MemberKeyWrap> memberWraps,
  required Uint8List escrowWrap,
}) {
  if (escrowWrap.length != epochKeyEscrowWrapBytes) {
    throw SyncRejection(
      SyncRejectionReason.malformedKeyWrap,
      'an escrow wrap is $epochKeyEscrowWrapBytes bytes, got ${escrowWrap.length}',
    );
  }
  final sorted = [...memberWraps]..sort((a, b) {
        final byMember = _compareBytes(uuidToBytes(a.memberId), uuidToBytes(b.memberId));
        return byMember != 0 ? byMember : _compareBytes(a.kexKeyId, b.kexKeyId);
      });
  final count = Uint8List(4);
  ByteData.view(count.buffer).setUint32(0, sorted.length, Endian.big);
  final builder = BytesBuilder(copy: false)
    ..add(ascii.encode(keyWrapDigestDomain))
    ..add(_epochBytes(epoch))
    ..add(count);
  for (final entry in sorted) {
    if (entry.wrap.length != keyWrapBytes) {
      throw SyncRejection(
        SyncRejectionReason.malformedKeyWrap,
        'a keywrap is $keyWrapBytes bytes, got ${entry.wrap.length}',
      );
    }
    if (entry.kexKeyId.length != authorKeyIdBytes) {
      throw const SyncRejection(
        SyncRejectionReason.malformedKeyWrap,
        'kex_key_id must be 8 bytes',
      );
    }
    builder
      ..add(uuidToBytes(entry.memberId))
      ..add(entry.kexKeyId)
      ..add(crypto.sha256.convert(entry.wrap).bytes);
  }
  builder.add(crypto.sha256.convert(escrowWrap).bytes);
  return Uint8List.fromList(crypto.sha256.convert(builder.toBytes()).bytes);
}

/// The 32-byte X25519 scalar an ephemeral keypair is generated from.
///
/// Its own constant rather than a borrowed key width, for the reason
/// `keySeedBytes` in `member_identity.dart` is: seed width and public-key width are
/// independent quantities that merely happen to agree here.
const int keyWrapSeedBytes = 32;

/// `HKDF-SHA256(X25519(sk, peer_pk), salt = "", info)`.
///
/// Both directions of the wrap go through this one function: an asymmetry between
/// the sealing and the opening key schedule is the kind of bug that only shows up
/// as "the wrap never opens", long after the bytes are frozen.
Future<SecretKey> _wrapKey({
  required SimpleKeyPair keyPair,
  required Uint8List peerPublicKey,
  required Uint8List info,
}) async {
  final shared = await _kex.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
  );
  return _hkdf.deriveKey(
    secretKey: SecretKey(await shared.extractBytes()),
    // `nonce` is this package's name for RFC 5869's *salt*, and empty means the
    // RFC's default of HashLen zero bytes. The Python side hand-rolls the same
    // reading (PyNaCl ships no HKDF) and the golden vectors prove the two agree.
    nonce: const <int>[],
    info: info,
  );
}

int _compareBytes(Uint8List a, Uint8List b) {
  for (var index = 0; index < a.length && index < b.length; index++) {
    if (a[index] != b[index]) return a[index] - b[index];
  }
  return a.length - b.length;
}

/// [length] bytes drawn from [random]. Shared with the escrow's own draw.
Uint8List randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
