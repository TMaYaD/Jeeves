/// What a rotation resume may do about a refusal, as a table over `(status, code)`.
///
/// **One class, one file** (the `sync_health.dart` precedent), and pure: no
/// database, no clock, no server, so the whole table is unit-testable on its own.
///
/// The resume makes two server calls — `POST /w/{w}/ops` to drain a rotate that
/// was authored but never flushed, and `PUT /w/{w}/keywraps` to publish the
/// prepared wrap set — and a refusal from one is not interchangeable with a
/// refusal from the other. Hence [RotationResumeSurface]: the transient and
/// unknown-code rules are shared, only the permanent code sets differ.
///
/// **There is no `default: retry`, and that is the point of the design.** The
/// defect this exists to correct (#627) was one code nobody had enumerated
/// falling into an "offline or transient" arm and being re-attempted on every
/// pull for ever. Transient statuses are matched *positively*; anything not
/// positively matched is [RotationResumeDisposition.retryBounded], so a future
/// server code cannot silently join the retry-forever path, and the alarm it
/// eventually raises carries that code verbatim rather than folded into another
/// code's meaning.
library;

import 'sync_transport.dart';

/// Which of the resume's two server calls was refused.
enum RotationResumeSurface {
  /// `PUT /w/{w}/keywraps` — [WorkspaceKeyCeremony.publish], one call per pending
  /// epoch, so a verdict here *is* attributable to one pending record.
  publish,

  /// `POST /w/{w}/ops` — `SyncClient.flushOutbox`, one call per Workspace, so a
  /// verdict here is **not** attributable to any one pending record. A caller must
  /// never terminalise a record from this surface.
  flush,
}

/// What the resume does with one refusal.
enum RotationResumeDisposition {
  /// Delete the record: nothing materialised, so nothing is stranded by dropping
  /// it. Only ever safe **after a flush that succeeded** — see the caller.
  discard,

  /// Leave the record and re-attempt on the next trigger, with no budget spent.
  /// Reserved for refusals that carry no verdict at all: offline, or a server
  /// that did not get as far as judging the request.
  retry,

  /// Leave the record, spend one attempt from a bounded per-process budget
  /// ([maxUnclassifiedResumeRefusalAttempts]), and on exhaustion raise the alarm
  /// and stop re-attempting **for this process only**, persisting nothing.
  ///
  /// The verdict for everything this build cannot name. A relaunch re-attempts
  /// under a fresh budget, so a transient-but-unclassified code self-heals while
  /// a genuinely permanent one costs a handful of calls plus a standing alarm —
  /// and no unknown code can ever produce a durable terminal record.
  retryBounded,

  /// A table-classified permanent refusal: no retry can change the answer.
  ///
  /// Named for the verdict rather than its effect, because the effect differs per
  /// surface — on [RotationResumeSurface.publish] the caller terminalises the
  /// record, on [RotationResumeSurface.flush] it may only raise the alarm.
  permanent,
}

/// How many times an unclassified refusal is re-attempted before the alarm goes
/// up, counted **in memory** and therefore per process.
///
/// Small on purpose: the budget exists to bound churn, not to outlast a rolling
/// deploy. The consequence is stated rather than glossed — a frequently-killed
/// mobile app may never exhaust it, and will keep re-attempting an unclassified
/// refusal a few times per launch. That is the fail-safe direction (an unknown
/// code never becomes durably final) and it is bounded for as long as the process
/// lives, which is the bound that matters.
const int maxUnclassifiedResumeRefusalAttempts = 5;

/// The classification, as one expression over `(statusCode, code)`.
RotationResumeDisposition dispositionForResumeRefusal(
  SyncTransportException refusal, {
  required RotationResumeSurface surface,
}) {
  // Transient first, and positively: these are the only refusals that carry no
  // verdict on the request, so they are the only ones an unbounded retry is
  // honest about.
  if (_isTransient(refusal)) return RotationResumeDisposition.retry;
  final code = refusal.code;
  // A 4xx whose `detail` was not a JSON object leaves `code` null — prose, or
  // FastAPI's `RequestValidationError`, whose `detail` is a *list* so
  // `_detailOf` returns `{}` (`http_sync_transport.dart`). Unnameable is not
  // transient: it gets the bounded budget like any other unknown.
  if (code == null) return RotationResumeDisposition.retryBounded;
  switch (surface) {
    case RotationResumeSurface.publish:
      if (code == rotateNotMaterialisedCode) {
        return RotationResumeDisposition.discard;
      }
      if (_permanentPublishCodes.contains(code)) {
        return RotationResumeDisposition.permanent;
      }
      return RotationResumeDisposition.retryBounded;
    case RotationResumeSurface.flush:
      if (_permanentFlushCodes.contains(code)) {
        return RotationResumeDisposition.permanent;
      }
      return RotationResumeDisposition.retryBounded;
  }
}

/// A refusal that carries no verdict on the request.
///
/// `statusCode == null` is [SyncTransportException.isUnreachable] — the offline
/// case. 5xx is the server failing rather than judging. 408/429 are explicitly
/// "ask again", and a 401 is a credential this device re-mints on its next
/// attach, not a statement about the wrap set.
bool _isTransient(SyncTransportException refusal) {
  final status = refusal.statusCode;
  if (status == null) return true;
  if (status >= 500) return true;
  return status == 401 || status == 408 || status == 429;
}

/// `PUT /w/{w}/keywraps` refusals no retry can change (`backend/app/sync/routes.py`,
/// `put_keywraps`).
///
/// Every one is a verdict on bytes that are already fixed: the digest the log
/// committed to, or the shape of a set whose every field the digest covers. A set
/// that hashes to a different digest can never become the digest the log
/// committed to, and a re-`prepare` draws fresh entropy rather than re-forming
/// these bytes.
const Set<String> _permanentPublishCodes = {
  // 422: the set does not hash to the digest the log committed to.
  keyWrapDigestMismatchCode,
  // 409: an epoch's wraps are written once, and a different set is not a later
  // caller's to substitute.
  'keywrap_already_written',
  // 422, the payload-shape family — a verdict on the widths and identities inside
  // the set, all of which the digest covers.
  'malformed_key_epoch',
  'malformed_escrow_wrap',
  'malformed_keywrap',
  'malformed_kex_key_id',
  'malformed_keywrap_digest',
  'missing_keywrap_digest',
  'duplicate_keywrap_member',
  'unknown_keywrap_member',
  'kex_key_id_not_registered',
  // 403, the outermost gate on every Workspace route: the v1 Workspace id space
  // is closed, and no retry widens it.
  workspaceNotDerivableCode,
};

/// `POST /w/{w}/ops` refusals no retry can change.
///
/// The op is already signed, so anything the server judges *about the op* is
/// final: re-posting the same bytes gets the same answer, and the client has no
/// path that re-signs them. `author_chain_conflict` and `genesis_not_first` are
/// absent because `SyncClient.flushOutbox` handles both itself and never rethrows
/// them.
const Set<String> _permanentFlushCodes = {
  // 409: the loser of a rotation race. Its `from_epoch` is signed into the op, so
  // it can never become the epoch the Workspace actually stands at. This is the
  // reachability story behind #627 — two devices starting a rotation inside one
  // pull interval, no crash required — and the queue behind it is #647's to drain.
  rotateEpochConflictCode,
  // 409: a signed `key_epoch` that the Workspace has moved past, or has not
  // reached. Same argument — the epoch is in the authenticated header.
  'key_epoch_stale',
  'key_epoch_unknown',
  // 409: an op into a Workspace with no genesis, posted by a device that is not
  // authoring one.
  'workspace_not_created',
  // 422: this author's chain shape, as signed.
  'member_register_not_first',
  'control_chain_break',
  // 403.
  workspaceNotDerivableCode,
  noLiveGrantRefusalCode,
};

/// Deliberately **not** classified, and listed rather than left absent.
///
/// The whole origin of #627 was a code nobody had enumerated, so an unlisted code
/// reads as an overlooked one. Each of these gets [RotationResumeDisposition.retryBounded]
/// on purpose:
///
/// * `keywrap_requires_owner` and `no_live_grant` on the **publish** surface — a
///   revoked or non-owner Device is a dead end for *this* credential, which a
///   re-grant could in principle revive. Under the bounded verdict that costs
///   nothing durable, so the re-grant window stays open.
/// * every remaining `POST /w/{w}/ops` 422 — the control-payload vocabulary
///   (`cert_*`, `prune_target_*`, `unsupported_control_type`, and the
///   `ControlPayloadError` reasons). They *are* verdicts on signed bytes, but on
///   the flush surface `permanent` and `retryBounded` converge on the same alarm
///   and neither persists anything, so mirroring an open server-side set into a
///   client table would buy a handful of saved POSTs at the price of a list that
///   drifts — which is the failure mode this module exists to prevent.
const Set<String> knownUnclassifiedResumeRefusalCodes = {
  'keywrap_requires_owner',
  noLiveGrantRefusalCode,
};
