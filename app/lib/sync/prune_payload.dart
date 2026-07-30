/// The class-5 prune payload: what a compaction supersedes, and its proof.
///
/// Mirror of `backend/app/sync/prune_payload.py`, field for field, and pinned by
/// `spec/sync/envelope_v1_vectors.json`.
///
/// ```json
/// {
///   "compaction": {"op_id": "<uuid>"},
///   "targets": [
///     {
///       "seq": <transport seq>,
///       "author_member_id": "<uuid>",
///       "author_seq": <n>,
///       "envelope_hash": "<hex64>"
///     }
///   ]
/// }
/// ```
///
/// **Why a target is more than a seq** (ADR-0038). The proposal says a prune
/// "enumerates the seqs its compaction supersedes", and a transport seq is not
/// enough, because of a structural fact about entity-level compaction: an author's
/// chain interleaves many entities' ops, so pruning one entity's ops removes
/// positions *inside* every contributing author's chain rather than truncating a
/// prefix. A fresh device verifying a survivor at `author_seq N` needs to know
/// that `head+1 .. N-1` were legitimately removed **and** the envelope hash at
/// `N-1` to check `prev_author_hash` against. The attestation carries both.
///
/// **Server-readable by design**, which is why prune ops are `plaintext_v1` for
/// ever ([SyncRejectionReason.encryptedPruneOp]): the server acts on this payload
/// to stamp `ops.compacted_by`, and it can afford to read it because the
/// enumeration is content-free — seqs, author positions and hashes, and nothing
/// about what any op said. The second deliberate exception to content-blindness,
/// the first being control ops.
///
/// Three rules are **shape** rules, refused at decode wherever the bytes are held:
/// an empty enumeration, a duplicate target, and more targets than one op may
/// carry. Refusing duplicates here is what leaves the server's materialisation
/// rowcount check exactly one possible cause — a concurrent prune — so a race can
/// never be misreported as a malformed payload or the reverse.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'envelope.dart';

/// An envelope hash is exactly [prevAuthorHashBytes] * 2 lowercase hex characters — SHA-256 over the
/// whole envelope, spelled the way an HLC member id is spelled: one casing, no
/// normalisation, because a codec that accepted another spelling would accept
/// attestations its peer refuses.
final RegExp _envelopeHashHexPattern =
    RegExp('^[0-9a-f]{${prevAuthorHashBytes * 2}}\$');

/// not tunable per call: how many ops one prune may attest. It bounds the single
/// `UPDATE` the server runs and the walk every client runs, and it is the same
/// order of magnitude as [maxOpsPerBatch]'s cousin on the server because a
/// compaction pass needing more than this is one that should be split.
const int maxPruneTargets = 1000;

/// One superseded op, attested well enough to chain past it.
///
/// [envelopeHash] is what a verifier needs and [seq] is what the server needs;
/// [authorMemberId]/[authorSeq] tie the two together, and the server cross-checks
/// all four against the envelope it holds before it stamps anything.
class PruneTarget {
  const PruneTarget({
    required this.seq,
    required this.authorMemberId,
    required this.authorSeq,
    required this.envelopeHash,
  });

  factory PruneTarget.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'a prune target must be a JSON object',
      );
    }
    final seq = raw['seq'];
    if (seq is! int || seq <= 0) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        "a prune target's seq must be a positive integer",
      );
    }
    final authorMemberId = raw['author_member_id'];
    if (authorMemberId is! String || !isCanonicalUuid(authorMemberId)) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        "a prune target's author_member_id must be a canonical lowercase UUID",
      );
    }
    final authorSeq = raw['author_seq'];
    if (authorSeq is! int || authorSeq <= 0) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        "a prune target's author_seq must be a positive integer",
      );
    }
    final envelopeHash = raw['envelope_hash'];
    if (envelopeHash is! String ||
        !_envelopeHashHexPattern.hasMatch(envelopeHash)) {
      throw SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        "a prune target's envelope_hash must be ${prevAuthorHashBytes * 2} "
        'lowercase hex characters',
      );
    }
    return PruneTarget(
      seq: seq,
      authorMemberId: authorMemberId,
      authorSeq: authorSeq,
      envelopeHash: _bytesOfHex(envelopeHash),
    );
  }

  final int seq;
  final String authorMemberId;
  final int authorSeq;
  final Uint8List envelopeHash;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'author_member_id': authorMemberId,
        'author_seq': authorSeq,
        'envelope_hash': _hexOfBytes(envelopeHash),
      };

  @override
  bool operator ==(Object other) =>
      other is PruneTarget &&
      other.seq == seq &&
      other.authorMemberId == authorMemberId &&
      other.authorSeq == authorSeq &&
      sameBytes(other.envelopeHash, envelopeHash);

  @override
  int get hashCode =>
      Object.hash(seq, authorMemberId, authorSeq, _hexOfBytes(envelopeHash));

  @override
  String toString() => 'PruneTarget(seq: $seq, $authorMemberId/$authorSeq)';
}

/// The compaction this prune stands behind, and every op it supersedes.
class PrunePayload {
  const PrunePayload({required this.compactionOpId, required this.targets});

  factory PrunePayload.decode(Uint8List payload) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(payload));
    } on FormatException catch (error) {
      throw SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'prune payload is not UTF-8 JSON: $error',
      );
    }
    if (raw is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'prune payload must be a JSON object',
      );
    }
    final compaction = raw['compaction'];
    if (compaction is! Map<String, dynamic>) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'prune payload must name its compaction op',
      );
    }
    final compactionOpId = compaction['op_id'];
    if (compactionOpId is! String || !isCanonicalUuid(compactionOpId)) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'compaction.op_id must be a canonical lowercase UUID string',
      );
    }
    final rawTargets = raw['targets'];
    if (rawTargets is! List) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPrunePayload,
        'targets must be an array',
      );
    }
    final targets = [for (final entry in rawTargets) PruneTarget.fromJson(entry)];
    requirePruneShape(targets);
    return PrunePayload(compactionOpId: compactionOpId, targets: targets);
  }

  final String compactionOpId;
  final List<PruneTarget> targets;

  Map<String, Object?> toJson() => {
        'compaction': {'op_id': compactionOpId},
        'targets': [for (final target in targets) target.toJson()],
      };

  /// Shape-checked on the way out as well as in.
  ///
  /// Authoring goes through the same rules a receiver applies, so a prune no peer
  /// would accept is never signed — the discipline `capture()` follows for content
  /// payloads.
  Uint8List encode() {
    requirePruneShape(targets);
    return Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  }

  /// The attestations this payload makes about one author, ascending.
  List<PruneTarget> targetsOf(String authorMemberId) => [
        for (final target in targets)
          if (target.authorMemberId == authorMemberId) target,
      ]..sort((a, b) => a.authorSeq.compareTo(b.authorSeq));

  /// Every author this prune attests a position of.
  Set<String> get attestedAuthors => {
        for (final target in targets) target.authorMemberId,
      };

  @override
  bool operator ==(Object other) =>
      other is PrunePayload &&
      other.compactionOpId == compactionOpId &&
      other.targets.length == targets.length &&
      List.generate(targets.length, (index) => index)
          .every((index) => other.targets[index] == targets[index]);

  @override
  int get hashCode => Object.hash(compactionOpId, Object.hashAll(targets));
}

/// The three shape rules, in the order a reader hits them.
void requirePruneShape(List<PruneTarget> targets) {
  if (targets.isEmpty) {
    throw const SyncRejection(
      SyncRejectionReason.pruneTargetsEmpty,
      'a prune must attest at least one op',
    );
  }
  if (targets.length > maxPruneTargets) {
    throw SyncRejection(
      SyncRejectionReason.pruneTargetsTooMany,
      'a prune may attest at most $maxPruneTargets ops, not ${targets.length}',
    );
  }
  if ({for (final target in targets) target.seq}.length != targets.length) {
    throw const SyncRejection(
      SyncRejectionReason.pruneDuplicateTarget,
      'two prune targets name one transport seq',
    );
  }
  final positions = {
    for (final target in targets) '${target.authorMemberId}/${target.authorSeq}',
  };
  if (positions.length != targets.length) {
    throw const SyncRejection(
      SyncRejectionReason.pruneDuplicateTarget,
      'two prune targets name one author position',
    );
  }
}

String _hexOfBytes(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _bytesOfHex(String hex) => Uint8List.fromList([
      for (var index = 0; index < hex.length; index += 2)
        int.parse(hex.substring(index, index + 2), radix: 16),
    ]);
