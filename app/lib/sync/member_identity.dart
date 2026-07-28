/// Stub Member identity: a self-generated keypair with no chain behind it.
///
/// #548 replaces the trust model with ADR-0028's Root chain — a device unwraps
/// the passphrase escrow, obtains Root, and signs its own Root-signed
/// MemberRegister. Until then a device generates its own keypair and the server
/// simply stores it, which means clients verifying against the registry are
/// trusting the server (review F1). That is knowingly accepted for pre-launch
/// dev data, and it is the one thing here that is a placeholder rather than a
/// stub: the *shape* below is what #548 keeps.
///
/// Keys are held in memory. Keychain/Keystore storage is review F22 and #548's
/// problem too.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'envelope.dart';
import 'hlc.dart';
import 'sync_transport.dart';

const Uuid _uuid = Uuid();

/// This device's Member id and signing key.
class MemberIdentity {
  MemberIdentity._(this.memberId, this.signer);

  /// [seed] makes a device's key deterministic, which the harness relies on to
  /// re-open a "restarted" device with the same identity.
  static Future<MemberIdentity> generate({String? memberId, Uint8List? seed}) async {
    final signer = await EnvelopeSigner.fromSeed(seed ?? _randomSeed());
    return MemberIdentity._(memberId ?? _uuid.v4(), signer);
  }

  final String memberId;
  final EnvelopeSigner signer;

  String get memberIdHex => memberIdToHex(memberId);

  Uint8List get signPk => signer.signPublicKey;

  /// Computed locally with the same derivation the server applies, so the
  /// header's `author_key_id` and the registry's agree without a round-trip.
  Uint8List get keyId => signer.keyId;

  static Uint8List _randomSeed() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(signPublicKeyBytes, (_) => random.nextInt(256)),
    );
  }
}

/// The verifying keys this device knows, keyed by author and key id.
///
/// `author_key_id` selects *which* of an author's keys verifies an op, so a key
/// rotation (#548) is a new entry rather than an overwrite. An op naming a key
/// this directory has never seen is refused, never guessed at.
class MemberDirectory {
  final Map<String, Uint8List> _keys = {};

  static String _slot(String memberId, Uint8List keyId) =>
      '$memberId/${_hex(keyId)}';

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  void remember(MemberRecord record) {
    _keys[_slot(record.memberId, record.keyId)] = record.signPk;
  }

  void rememberAll(Iterable<MemberRecord> records) => records.forEach(remember);

  /// The public key for this author and key id, or a fail-closed refusal.
  Uint8List publicKeyFor(String memberId, Uint8List keyId) {
    final key = _keys[_slot(memberId, keyId)];
    if (key == null) {
      throw SyncRejection(
        SyncRejectionReason.unknownAuthorKey,
        'no registered key ${_hex(keyId)} for member $memberId',
      );
    }
    return key;
  }
}
