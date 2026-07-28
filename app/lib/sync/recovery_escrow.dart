/// The passphrase-wrapped Root: blob format, KDF floor, and the signed record.
///
/// This is how a new Device obtains Root with nothing but the passphrase
/// (ADR-0028, proposal § Identity and keys). The blob is client-defined and the
/// server never parses it — its only cryptographic duty is refusing a write
/// whose Root signature does not verify against the `root_pk` already in the
/// slot (F16).
///
/// ```
/// blob = magic "JVE1"          4B
///     || m_cost_kib   u32      4B
///     || t_cost       u32      4B
///     || parallelism  u8       1B
///     || salt                 16B
///     || nonce                24B     (XChaCha20)
///     || XChaCha20-Poly1305(
///            key = Argon2id(passphrase, salt, params),
///            nonce,
///            aad = the 53 header bytes above,
///            plaintext = root_sk 32B || master_wrap_key 32B)
///
/// root_sig = Ed25519(root_sk,
///     "jeeves/escrow/v1" || workspace_id (16 raw bytes)
///                        || version (u64 big-endian) || blob)
/// ```
///
/// **The KDF parameters live inside the blob, and the floor is enforced on read
/// *and* write** — a below-floor blob is refused before any KDF work runs,
/// which is what closes F12's weakened-params-at-write attack. Params being
/// data means a future native implementation can raise them without a protocol
/// change.
///
/// **`workspace_id` sits inside the signed preimage**, so a blob signed for one
/// Workspace can never be replayed into another's slot, even by an
/// honest-but-confused server.
///
/// `masterWrapKey` is minted and escrowed now even though nothing wraps under
/// it until #554: a constant blob shape is the structural tidy-up, and it makes
/// a passphrase change a pure re-wrap for ever.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'envelope.dart';

const List<int> escrowBlobMagic = [0x4A, 0x56, 0x45, 0x31]; // "JVE1"
const int escrowSaltBytes = 16;
const int escrowNonceBytes = 24;

/// `root_sk 32B || master_wrap_key 32B` — a constant plaintext width, for ever.
const int escrowSecretBytes = 64;
const int poly1305TagBytes = 16;
const int escrowBlobHeaderBytes = 4 + 4 + 4 + 1 + escrowSaltBytes + escrowNonceBytes;
const int escrowBlobBytes = escrowBlobHeaderBytes + escrowSecretBytes + poly1305TagBytes;

const int rootSecretKeyBytes = 32;
const int masterWrapKeyBytes = 32;

/// The Argon2id floor (review F12). Production values; the harness lowers them
/// through the same checking code path rather than around it.
const int argon2idFloorMemoryKib = 65536;
const int argon2idFloorTimeCost = 3;
const int argon2idFloorParallelism = 1;

/// A slot's first write. Anything else on create is a version regression.
const int firstEscrowVersion = 1;

/// Why an escrow operation was refused.
///
/// A namespace of its own, deliberately: these are not quarantined ops, and
/// several of them are **alarms** rather than user errors — see
/// [RecoveryEscrowException].
enum RecoveryEscrowFailure {
  /// The blob does not begin "JVE1", or is not the right length.
  malformedBlob('malformed_escrow_blob'),

  /// Parameters below the floor. Refused *before* any KDF work runs, on read
  /// and on write alike.
  kdfBelowFloor('kdf_below_floor'),

  /// AEAD failure with no pinned Root: the honest reading is "wrong
  /// passphrase". That residue is exactly what TOFU-against-the-passphrase
  /// means, and it is accepted.
  wrongPassphrase('wrong_passphrase'),

  /// The record is not signed by the Root this device pinned. **An alarm**: a
  /// device holding a pin checks the signature *before* prompting, so this is
  /// never surfaced as "wrong passphrase".
  rootMismatch('escrow_root_mismatch'),

  /// A version below the highest this device has seen for the slot. **An
  /// alarm**: the server is serving an older escrow than it once did.
  versionRollback('escrow_version_rollback');

  const RecoveryEscrowFailure(this.code);

  final String code;
}

class RecoveryEscrowException implements Exception {
  const RecoveryEscrowException(this.failure, this.message);

  final RecoveryEscrowFailure failure;
  final String message;

  /// True when this is a server-integrity event rather than a user mistake.
  ///
  /// F12/Q7: a substituted or rolled-back blob must alarm, not prompt. Only
  /// [RecoveryEscrowFailure.wrongPassphrase] is a prompt.
  bool get isAlarm => failure != RecoveryEscrowFailure.wrongPassphrase;

  @override
  String toString() => 'RecoveryEscrowException(${failure.code}): $message';
}

/// The Argon2id cost parameters carried inside a blob.
class Argon2idParameters {
  const Argon2idParameters({
    required this.memoryKib,
    required this.timeCost,
    required this.parallelism,
  });

  /// The production floor, and the default for a fresh blob.
  static const Argon2idParameters floor = Argon2idParameters(
    memoryKib: argon2idFloorMemoryKib,
    timeCost: argon2idFloorTimeCost,
    parallelism: argon2idFloorParallelism,
  );

  final int memoryKib;
  final int timeCost;
  final int parallelism;

  bool meetsFloor(Argon2idParameters floorParameters) =>
      memoryKib >= floorParameters.memoryKib &&
      timeCost >= floorParameters.timeCost &&
      parallelism >= floorParameters.parallelism;

  @override
  String toString() => 'Argon2id(m=$memoryKib KiB, t=$timeCost, p=$parallelism)';
}

/// What the blob protects: Root's secret key and the master wrap key.
class EscrowedSecrets {
  const EscrowedSecrets({required this.rootSecretKey, required this.masterWrapKey});

  final Uint8List rootSecretKey;

  /// Escrowed now, read by nothing until #554's KeyWraps.
  final Uint8List masterWrapKey;
}

/// The four opaque fields the server stores, as one value.
class RecoveryEscrowRecord {
  const RecoveryEscrowRecord({
    required this.version,
    required this.blob,
    required this.rootSig,
    required this.rootPk,
  });

  final int version;
  final Uint8List blob;
  final Uint8List rootSig;
  final Uint8List rootPk;
}

/// `"jeeves/escrow/v1" || workspace_id || version (u64 BE) || blob`.
Uint8List escrowSigningInput(String workspaceId, int version, Uint8List blob) {
  final versionBytes = Uint8List(8);
  ByteData.view(versionBytes.buffer)
    ..setUint32(0, version ~/ 0x100000000, Endian.big)
    ..setUint32(4, version % 0x100000000, Endian.big);
  return domainSeparated(
    signingDomainEscrowV1,
    [uuidToBytes(workspaceId), versionBytes, blob],
  );
}

/// Throws unless [record] is signed by [rootPk] for this Workspace.
///
/// A device holding a pinned Root runs this **before** any passphrase prompt:
/// a failure here is a server-integrity alarm, not a typo (F12/Q7).
Future<void> verifyEscrowRecordSignature(
  RecoveryEscrowRecord record,
  String workspaceId,
  Uint8List rootPk,
) async {
  final ok = await verifyDomainSeparated(
    escrowSigningInput(workspaceId, record.version, record.blob),
    record.rootSig,
    rootPk,
  );
  if (!ok) {
    throw const RecoveryEscrowException(
      RecoveryEscrowFailure.rootMismatch,
      'the escrow record is not signed by the pinned Root for this workspace',
    );
  }
}

/// Wrap [secrets] under [passphrase] into a v1 blob.
///
/// [parameters] must meet [floor]; the check runs before the KDF, so a caller
/// cannot weaken the blob it is about to write (F12).
Future<Uint8List> wrapEscrowBlob({
  required String passphrase,
  required EscrowedSecrets secrets,
  Argon2idParameters parameters = Argon2idParameters.floor,
  Argon2idParameters floor = Argon2idParameters.floor,
  Random? random,
}) async {
  _requireAtOrAboveFloor(parameters, floor);
  final entropy = random ?? Random.secure();
  final salt = _randomBytes(entropy, escrowSaltBytes);
  final nonce = _randomBytes(entropy, escrowNonceBytes);
  final header = _blobHeader(parameters, salt, nonce);

  final plaintext = Uint8List(escrowSecretBytes)
    ..setRange(0, rootSecretKeyBytes, secrets.rootSecretKey)
    ..setRange(rootSecretKeyBytes, escrowSecretBytes, secrets.masterWrapKey);
  final secretBox = await _cipher.encrypt(
    plaintext,
    secretKey: await _deriveKey(passphrase, salt, parameters),
    nonce: nonce,
    aad: header,
  );

  return (BytesBuilder(copy: false)
        ..add(header)
        ..add(secretBox.cipherText)
        ..add(secretBox.mac.bytes))
      .toBytes();
}

/// Unwrap a v1 blob. Refuses below-floor parameters before any KDF work.
Future<EscrowedSecrets> unwrapEscrowBlob({
  required Uint8List blob,
  required String passphrase,
  Argon2idParameters floor = Argon2idParameters.floor,
}) async {
  final parameters = readEscrowBlobParameters(blob, floor: floor);
  final salt = Uint8List.sublistView(blob, 13, 13 + escrowSaltBytes);
  final nonce = Uint8List.sublistView(
    blob,
    13 + escrowSaltBytes,
    escrowBlobHeaderBytes,
  );
  final header = Uint8List.sublistView(blob, 0, escrowBlobHeaderBytes);
  final cipherText = Uint8List.sublistView(
    blob,
    escrowBlobHeaderBytes,
    escrowBlobHeaderBytes + escrowSecretBytes,
  );
  final mac = Uint8List.sublistView(blob, escrowBlobHeaderBytes + escrowSecretBytes);

  final List<int> plaintext;
  try {
    plaintext = await _cipher.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: await _deriveKey(passphrase, salt, parameters),
      aad: header,
    );
  } on SecretBoxAuthenticationError {
    // With no pinned Root behind it, an AEAD failure reads as a wrong
    // passphrase. A device that *does* hold a pin has already checked the
    // record's signature by now, so it never reaches this line for a
    // substituted blob.
    throw const RecoveryEscrowException(
      RecoveryEscrowFailure.wrongPassphrase,
      'the escrow blob did not authenticate under this passphrase',
    );
  }
  return EscrowedSecrets(
    rootSecretKey: Uint8List.fromList(plaintext.sublist(0, rootSecretKeyBytes)),
    masterWrapKey: Uint8List.fromList(plaintext.sublist(rootSecretKeyBytes)),
  );
}

/// The parameters a blob declares, checked against [floor].
///
/// Split out so a caller can refuse a blob *without* running the KDF — that is
/// the whole point of the floor.
Argon2idParameters readEscrowBlobParameters(
  Uint8List blob, {
  Argon2idParameters floor = Argon2idParameters.floor,
}) {
  if (blob.length != escrowBlobBytes) {
    throw RecoveryEscrowException(
      RecoveryEscrowFailure.malformedBlob,
      'blob is ${blob.length} bytes, expected $escrowBlobBytes',
    );
  }
  for (var index = 0; index < escrowBlobMagic.length; index++) {
    if (blob[index] != escrowBlobMagic[index]) {
      throw const RecoveryEscrowException(
        RecoveryEscrowFailure.malformedBlob,
        'blob does not begin with the JVE1 magic',
      );
    }
  }
  final view = ByteData.view(blob.buffer, blob.offsetInBytes, escrowBlobHeaderBytes);
  final parameters = Argon2idParameters(
    memoryKib: view.getUint32(4, Endian.big),
    timeCost: view.getUint32(8, Endian.big),
    parallelism: blob[12],
  );
  _requireAtOrAboveFloor(parameters, floor);
  return parameters;
}

void _requireAtOrAboveFloor(Argon2idParameters parameters, Argon2idParameters floor) {
  if (!parameters.meetsFloor(floor)) {
    throw RecoveryEscrowException(
      RecoveryEscrowFailure.kdfBelowFloor,
      '$parameters is below the floor $floor',
    );
  }
}

final Cipher _cipher = Xchacha20.poly1305Aead();

Future<SecretKey> _deriveKey(
  String passphrase,
  Uint8List salt,
  Argon2idParameters parameters,
) =>
    Argon2id(
      memory: parameters.memoryKib,
      iterations: parameters.timeCost,
      parallelism: parameters.parallelism,
      hashLength: 32,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );

Uint8List _blobHeader(Argon2idParameters parameters, Uint8List salt, Uint8List nonce) {
  final header = Uint8List(escrowBlobHeaderBytes);
  header.setRange(0, 4, escrowBlobMagic);
  ByteData.view(header.buffer)
    ..setUint32(4, parameters.memoryKib, Endian.big)
    ..setUint32(8, parameters.timeCost, Endian.big);
  header[12] = parameters.parallelism;
  header.setRange(13, 13 + escrowSaltBytes, salt);
  header.setRange(13 + escrowSaltBytes, escrowBlobHeaderBytes, nonce);
  return header;
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));
