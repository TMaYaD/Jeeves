/// The key-plane half of the Workspace ceremonies: building, publishing and
/// adopting an epoch's key material.
///
/// Everything here takes `master_wrap_key` as an argument and never goes near the
/// recovery escrow itself. Recovering Root and the master wrap key from the
/// passphrase is `EnrolmentService`'s job — it owns the pin, the version high-water
/// mark and the substituted-blob alarm — so this class is the part that would
/// otherwise be duplicated between "the founding device keys a fresh Workspace",
/// "an enrolling device adopts the history" and "an owner rotates".
///
/// Three shapes, and the asymmetry between them is the design rather than an
/// oversight:
///
/// * **[WorkspaceKeyCeremony.prepare] then [WorkspaceKeyCeremony.publish]** are two
///   steps, because a rotation must commit to `keywrap_digest` in a *signed* op
///   before any wrap is uploaded. Preparing first is also what makes the
///   fail-before-authoring rule enforceable: a wrap set that cannot cover every
///   survivor throws here, with nothing authored and nothing published (review
///   F14a).
/// * **[WorkspaceKeyCeremony.adoptFromEscrow] uploads nothing.** An enrolling device
///   recovers every epoch key from the escrow wraps and stops there; it does *not*
///   add itself to an existing epoch's wrap set, because it cannot. The set is
///   committed to by a digest and `PUT /w/{w}/keywraps` refuses any other set for an
///   epoch already written — which is precisely the immutability that stops a
///   hostile server curating who can read an epoch. The device needs no wrap of its
///   own: the keys are in its own [WorkspaceKeyStore] from then on, and the next
///   rotation wraps to it like any other Member.
/// * **Epoch 0 carries its own digest** and every epoch above it does not. Nothing
///   rotated *to* epoch 0, so there is no signed op to have committed to it; the
///   founding client's own digest is stored as the commitment instead.
library;

import 'dart:math';
import 'dart:typed_data';

import 'control_payload.dart';
import 'envelope.dart';
import 'grants_view.dart';
import 'key_wraps.dart';
import 'sync_client.dart';

/// How long an epoch may stand before a rotation is due.
///
/// Not configurable: it is a security cadence rather than a tuning knob, and the
/// only caller is the trigger that *offers* the ceremony — nothing rotates a
/// Workspace on a timer without the passphrase, because minting an epoch means
/// writing an escrow wrap under `master_wrap_key`.
const Duration quarterlyRotationInterval = Duration(days: 90);

/// One epoch's key and every wrap that delivers it, with the digest that commits
/// to the set.
///
/// Built before anything is authored and published after, so the object is what
/// travels between the two halves of a rotation.
class EpochKeySet {
  const EpochKeySet({
    required this.epoch,
    required this.workspaceKey,
    required this.memberWraps,
    required this.escrowWrap,
    required this.digest,
  });

  final int epoch;

  /// `K_{w,epoch}` — random, never derived.
  final Uint8List workspaceKey;

  /// One wrap per live-granted Member, sealed to its registered X25519 key.
  final List<MemberKeyWrap> memberWraps;

  /// The same key under `master_wrap_key`, so the passphrase alone recovers it.
  final Uint8List escrowWrap;

  /// `SHA-256` over the whole set. A `rotate` op names this before any wrap is
  /// uploaded, which is what lets the server refuse a set it was not promised.
  final Uint8List digest;

  Iterable<String> get recipients => memberWraps.map((wrap) => wrap.memberId);
}

class WorkspaceKeyCeremony {
  WorkspaceKeyCeremony({required this.client, Random? random})
      : _random = random ?? Random.secure();

  /// The client for the **one** Workspace this ceremony acts on. Keys are
  /// per-Workspace, so a User with two Workspaces runs this twice.
  final SyncClient client;

  /// Draws the epoch key, the ephemeral scalars and the wrap nonces.
  ///
  /// The harness seeds it to get reproducible devices; production passes nothing.
  /// Seeding it publishes the Workspace's content key, so this is the same seam —
  /// and the same warning — as `EnrolmentService`'s.
  final Random _random;

  /// Whether this device holds a key for the Workspace's current epoch.
  Future<bool> get isEncrypted async =>
      await client.workspaceKeys.keyFor(client.workspaceId, await client.epochFloor()) !=
      null;

  /// Build the wrap set for [epoch] over every Member with a live Grant.
  ///
  /// **Refuses before anything is authored** when a survivor cannot be wrapped to
  /// ([SyncRejectionReason.unwrappableGrant]). That ordering is the whole guarantee:
  /// the digest is committed to in a signed `rotate`, so a set that quietly omitted
  /// a Member would lock them out permanently and be attested by the owner's own
  /// signature. Blocked and surfaced is recoverable; staged is not.
  ///
  /// [excludeMemberId] is the revocation half of a `revoke`+`rotate` ceremony: the
  /// Member being cut off is not a survivor, and excluding it here is what makes the
  /// rotation *mean* something. Their Grants are read as live at this point, because
  /// the revoke has deliberately not been authored yet.
  ///
  /// Grants are deduplicated by Member — a Member holding two Grants gets one wrap,
  /// which is also what `PUT /w/{w}/keywraps` requires.
  Future<EpochKeySet> prepare({
    required int epoch,
    required Uint8List masterWrapKey,
    String? excludeMemberId,
    Uint8List? workspaceKey,
  }) async {
    final view = await client.grantsView();
    final survivors = <String>{};
    var excluded = false;
    for (final grant in view.grants.values) {
      if (!grant.isLive) continue;
      if (grant.memberId == excludeMemberId) {
        excluded = true;
        continue;
      }
      survivors.add(grant.memberId);
    }
    if (excludeMemberId != null && !excluded) {
      // The revocation half of the ceremony named a Member with no live Grant in
      // this view (stale id, wrong member): matching nothing would publish a wrap
      // set that still *includes* whoever the revoke was meant to cut off, attested
      // by the owner's own signature. Everything else here fails loudly before
      // authoring; this exclusion must not be the one that fails open.
      throw SyncRejection(
        SyncRejectionReason.unknownGrant,
        'no live Grant for $excludeMemberId in ${client.workspaceId}: refusing to '
        'rotate rather than publish a wrap set that does not exclude it',
      );
    }
    // Sorted, so a set built twice from one grants view is built in one order. The
    // digest sorts its own input, so this is about the *upload* being reproducible.
    final ordered = survivors.toList()..sort();

    final key = workspaceKey ?? randomBytes(_random, workspaceKeyBytes);
    final wraps = <MemberKeyWrap>[];
    for (final memberId in ordered) {
      final kex = client.directory.keyExchangeFor(memberId);
      if (kex == null) {
        throw SyncRejection(
          SyncRejectionReason.unwrappableGrant,
          'no verified KEX key for $memberId, which holds a live Grant: refusing '
          'to rotate rather than publish a wrap set that locks it out',
        );
      }
      if (client.directory.kindOf(memberId) != memberKindDevice) {
        // A Service is wrapped to a verified per-User KEX subkey, which no Service
        // has yet — Service enrolment does not exist. Refusing loudly is the only
        // honest answer: rotating anyway would cut the Service off with the owner's
        // own signature on the omission.
        throw SyncRejection(
          SyncRejectionReason.unwrappableGrant,
          '$memberId is a ${client.directory.kindOf(memberId)} and holds a live '
          'Grant; Service KeyWraps are not implemented, so this Workspace cannot '
          'rotate yet',
        );
      }
      wraps.add(MemberKeyWrap(
        memberId: memberId,
        kexKeyId: kex.kexKeyId,
        wrap: await wrapEpochKeyForMember(
          workspaceKey: key,
          kexPk: kex.kexPk,
          workspaceId: client.workspaceId,
          epoch: epoch,
          memberId: memberId,
          kexKeyId: kex.kexKeyId,
          random: _random,
        ),
      ));
    }

    final escrowWrap = await wrapEpochKeyForEscrow(
      workspaceKey: key,
      masterWrapKey: masterWrapKey,
      workspaceId: client.workspaceId,
      epoch: epoch,
      random: _random,
    );
    return EpochKeySet(
      epoch: epoch,
      workspaceKey: key,
      memberWraps: wraps,
      escrowWrap: escrowWrap,
      digest: keyWrapDigest(
        epoch: epoch,
        memberWraps: wraps,
        escrowWrap: escrowWrap,
      ),
    );
  }

  /// Upload the set, then — and only then — remember the key locally.
  ///
  /// The order matters. Remembering first would leave this device holding a key its
  /// peers were never given, and at epoch 0 (where the floor is already 0) it would
  /// immediately start authoring content nobody else could read. A failed PUT must
  /// leave the Workspace exactly as encrypted as it was.
  Future<void> publish(EpochKeySet set) async {
    await client.transport.putKeyWraps(
      client.workspaceId,
      epoch: set.epoch,
      wraps: set.memberWraps,
      escrowWrap: set.escrowWrap,
      // Epoch 0 has no `rotate` behind it, so its commitment travels in the body.
      // Above it the signed op is the authority and a body digest would be a second
      // claim the server could be asked to prefer.
      keyWrapDigest: set.epoch == 0 ? set.digest : null,
    );
    await client.workspaceKeys.remember(client.workspaceId, set.epoch, set.workspaceKey);
  }

  /// Learn every epoch key the escrow wraps carry. Returns how many were new.
  ///
  /// The bootstrap path, and the reason AC-2 holds with **no second device online**:
  /// the passphrase yields `master_wrap_key`, `GET /w/{w}/epoch-keys` yields every
  /// epoch's wrap, and the whole history decrypts. Epochs whose wraps have not been
  /// uploaded yet are simply not served, so there is nothing here to distinguish
  /// from a wrap that fails to open.
  ///
  /// A wrap that does *not* open is a fail-closed throw rather than a skip: under
  /// `master_wrap_key` there is no honest reason for it, and a bootstrap that
  /// silently adopted 3 of 4 epochs would look converged while a quarter of the
  /// history quarantined.
  Future<int> adoptFromEscrow({required Uint8List masterWrapKey}) async {
    var learned = 0;
    for (final record in await client.transport.fetchEpochKeys(client.workspaceId)) {
      if (await client.workspaceKeys.keyFor(client.workspaceId, record.epoch) != null) {
        continue;
      }
      await client.workspaceKeys.remember(
        client.workspaceId,
        record.epoch,
        await unwrapEpochKeyFromEscrow(
          escrowWrap: record.escrowWrap,
          masterWrapKey: masterWrapKey,
          workspaceId: client.workspaceId,
          epoch: record.epoch,
        ),
      );
      learned++;
    }
    return learned;
  }

  /// Whether the current epoch has stood longer than [maxEpochAge].
  ///
  /// The scheduled-rotation trigger, and it only ever *reports*: rotating needs
  /// `master_wrap_key` for the new epoch's escrow wrap, which lives behind the
  /// passphrase, so a quarterly rotation is a prompt rather than a background job.
  /// Caching the master wrap key on the device to make it unattended would move
  /// escrow material out from behind the passphrase for a convenience, which is the
  /// wrong side of that trade.
  ///
  /// False for a Workspace that is not encrypted yet — turning encryption on is an
  /// owner's decision, never a timer's.
  Future<bool> isRotationDue({
    required DateTime now,
    Duration maxEpochAge = quarterlyRotationInterval,
  }) async {
    if (!await isEncrypted) return false;
    final established = await client.currentEpochEstablishedAt();
    if (established == null) return false;
    return now.difference(established) >= maxEpochAge;
  }

  /// Every Member this ceremony would wrap to, for a caller that wants to show the
  /// set before running it.
  Future<List<DerivedGrant>> liveGrants() async =>
      (await client.grantsView()).grants.values.where((grant) => grant.isLive).toList();
}
