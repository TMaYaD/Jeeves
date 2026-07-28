/// The grants view a device derives from its own applied control log, and the
/// authorization verdict that reads it.
///
/// **Derived, never cached.** Control ops are few, so the view is recomputed at
/// read time from `applied_control_log`; per the naming rule a stored copy would
/// have to announce itself as one, and would then be free to go stale. What *is*
/// stored is the log — the evidence — and the view is a question asked of it.
///
/// **Positional, never current-state.** A content op at server seq S is
/// authorized iff its author holds a Grant permitting its `op_class` that was
/// live *at S*: `grantedSeq < S` and (`revokedBySeq` is null or `S <
/// revokedBySeq`). That is what keeps late arrivals honest — a gap-released op
/// predating a revocation must not be retro-quarantined just because the
/// revocation has since applied, or a device that saw it in time would diverge
/// from one that saw it late.
///
/// One residual is recorded rather than solved: **the server chooses the
/// revocation boundary via seq assignment**, so a hostile server can widen or
/// narrow the revoked window by how it orders a revoke against in-flight content.
/// Seq anchoring is still the right call, because anchoring on the certificate
/// HLC instead would let the revoked author backdate ops under the boundary.
library;

import 'control_payload.dart';
import 'envelope.dart';

/// One Grant as the view sees it: the fact, plus the two seqs that bound it.
class DerivedGrant {
  const DerivedGrant({
    required this.grantId,
    required this.memberId,
    required this.role,
    required this.granter,
    required this.grantedSeq,
    this.revokedBySeq,
  });

  final String grantId;
  final String memberId;
  final String role;

  /// `root`, or the granting Member's id — verbatim from the signed certificate.
  final String granter;

  /// The seq of the control op that made this Grant.
  final int grantedSeq;

  /// The seq of the control op that unmade it, or null while it is live.
  final int? revokedBySeq;

  /// Whether this Grant was live at server seq [seq].
  bool wasLiveAt(int seq) =>
      grantedSeq < seq && (revokedBySeq == null || seq < revokedBySeq!);

  /// Whether this Grant is live against the current head — the authoring-side
  /// question, since a new op's seq is assigned after everything applied.
  bool get isLive => revokedBySeq == null;
}

/// Every Grant a Workspace's applied control log has ever produced.
class GrantsView {
  const GrantsView(this.grants);

  /// Keyed by grant id, so revocation stays grant-granular (F19).
  final Map<String, DerivedGrant> grants;

  static const GrantsView empty = GrantsView({});

  Iterable<DerivedGrant> _of(String memberId) =>
      grants.values.where((grant) => grant.memberId == memberId);

  /// The roles [memberId] held at server seq [seq].
  Set<String> rolesAt(String memberId, int seq) => {
        for (final grant in _of(memberId))
          if (grant.wasLiveAt(seq)) grant.role,
      };

  /// The roles [memberId] holds against the current head.
  Set<String> liveRoles(String memberId) => {
        for (final grant in _of(memberId))
          if (grant.isLive) grant.role,
      };

  bool hasAnyGrant(String memberId) => _of(memberId).isNotEmpty;

  /// At least one Grant, none of them live — "revoked", as the index defines it.
  bool isRevoked(String memberId) =>
      hasAnyGrant(memberId) && liveRoles(memberId).isEmpty;

  /// Whether [memberId] held an *owner* Grant at [seq] — the authority a
  /// member-signed control op needs.
  bool wasOwnerAt(String memberId, int seq) => rolesAt(memberId, seq).contains(roleOwner);

  /// A live Grant with no current-epoch KeyWrap.
  ///
  /// Named and surfaced *now*, dormant until #554: with no KeyWraps the predicate
  /// is defined against epoch 0 and never fires. The vocabulary and the seam land
  /// here so #554 wires delivery rather than concepts.
  Iterable<DerivedGrant> orphanedGrants({int currentEpoch = 0, Set<String> keyWrappedGrantIds = const {}}) =>
      currentEpoch == 0
          ? const []
          : grants.values.where(
              (grant) => grant.isLive && !keyWrappedGrantIds.contains(grant.grantId),
            );

  /// The authorization verdict on one received op, at its own server seq.
  ///
  /// Returns null when the op is authorized, or the refusal to quarantine it
  /// under. The refusal is [SyncRejectionReason.noLiveGrant] in both the
  /// no-Grant and wrong-role cases, because the client's quarantine vocabulary
  /// answers *why was this op refused* rather than *which check fired*: a role
  /// that does not permit an op class is, for that op, no Grant at all.
  SyncRejection? verdictFor({
    required String authorMemberId,
    required int opClass,
    required int seq,
  }) {
    final roles = rolesAt(authorMemberId, seq);
    if (roles.isEmpty) {
      return SyncRejection(
        SyncRejectionReason.noLiveGrant,
        'member $authorMemberId held no live Grant at seq $seq'
        '${isRevoked(authorMemberId) ? ' (revoked)' : ''}',
      );
    }
    final allowed = roleOpClassMatrix[opClass] ?? const <String>{};
    if (roles.intersection(allowed).isEmpty) {
      return SyncRejection(
        SyncRejectionReason.noLiveGrant,
        'roles ${roles.toList()..sort()} do not permit op_class $opClass at seq $seq',
      );
    }
    return null;
  }
}
