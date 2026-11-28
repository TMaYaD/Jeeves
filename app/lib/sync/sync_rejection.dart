/// Why a change or an op is refused — shared by the op-log wire and the sync host.
///
/// The reason codes are persisted (`op_log.refused_reason`) and pinned by the
/// golden vectors, so they move with this type unchanged.
library;

/// Why an op was refused. The `code` strings are the contract shared with the
/// Python codec and with the golden vectors: both suites assert the *same*
/// rejection, not merely that something threw.
enum SyncRejectionReason {
  truncatedEnvelope('truncated_envelope'),
  envelopeTooShort('envelope_too_short'),
  unsupportedSuite('unsupported_suite'),
  unsupportedOpClass('unsupported_op_class'),
  invalidBodyLength('invalid_body_length'),
  payloadOverrunsBody('payload_overruns_body'),
  nonZeroPadding('non_zero_padding'),
  badSignature('bad_signature'),

  /// The envelope **header** names a Workspace this device did not pull from.
  ///
  /// Header-level and nothing else: it is an accusation against the *server*,
  /// which is the only party that chose what to serve here. A Root-signed
  /// document naming another Workspace is a different event with a different
  /// remediation and earns [certWorkspaceMismatch] instead — the two were one
  /// string until #580, which left a Quarantine row unable to say whether the
  /// header lied or the certificate did.
  workspaceMismatch('workspace_mismatch'),

  /// An `op_class = control` op wearing suite `aead_v1`.
  ///
  /// A **codec-level document invariant**, refused wherever the bytes are held.
  /// Control ops are unencrypted by design (review F2): the server materialises
  /// memberships, Grants and rotations out of their payloads and holds no key, so
  /// an encrypted one is not a stricter op — it is an op nobody can act on, and
  /// a client that tolerated it would be trusting a server that could no longer
  /// check anything. Carries a golden negative vector: both codecs must classify
  /// it identically.
  encryptedControlOp('encrypted_control_op'),

  /// An `op_class = prune` op wearing suite `aead_v1`.
  ///
  /// The sibling of [encryptedControlOp], forbidden for the same reason: the
  /// server materialises `ops.compacted_by` out of a prune's target enumeration
  /// and holds no key, so an encrypted prune is an op nobody can act on. The
  /// enumeration is content-free by construction — transport seqs, author
  /// positions and envelope hashes — so keeping it in the clear discloses nothing
  /// the header did not already. Carries a golden negative vector.
  encryptedPruneOp('encrypted_prune_op'),

  /// The AEAD did not authenticate under a key this device **holds**.
  ///
  /// Never a skipped row: the op quarantines *and* raises an
  /// `aead_failure` integrity alarm, because a key we hold plus bytes that do not
  /// authenticate under it is either a tampered body or a tampered header — the
  /// AAD is the header — and both are accusations rather than delivery gaps.
  /// Distinct from [missingEpochKey], which is the healable case.
  aeadFailure('aead_failure'),

  /// An op at a `key_epoch` this device holds no `K_{w,epoch}` for.
  ///
  /// Quarantined fail-closed, and *not* an alarm: a KeyWrap that has not arrived
  /// yet is a delivery gap, not misconduct. The standing state is surfaced through
  /// the orphaned-grant predicate, which triggers a bounded KeyWrap re-fetch before
  /// it escalates — the `GET /w/{w}/keywraps/me` freshness race after a rotation is
  /// exactly this, named rather than left as a mystery decryption failure.
  ///
  /// Client-only and stateful: the same envelope is readable for a device holding
  /// the wrap and a gap for one that does not, so it carries no golden vector.
  missingEpochKey('missing_epoch_key'),

  /// A content op at a `key_epoch` no `rotate` this device applied has established.
  ///
  /// The client mirror of the server's `key_epoch_unknown` ceiling (#590): the
  /// epoch floor doubles as the applied-epoch ceiling on receive, so content whose
  /// `key_epoch` exceeds `epochFloor()` is content from outside the rotation
  /// boundary this device's own control log has reached. Refused *before* any key
  /// lookup — the verdict is about the epoch, not about whether the wrap happens to
  /// be held (`refreshEpochKeys` fetches every epoch the server holds, so the key
  /// can arrive before the `rotate` that establishes its epoch).
  ///
  /// Quarantined fail-closed, and *not* an alarm: an epoch this device has not
  /// reached yet is a delivery-order fact, not misconduct — the same reading
  /// [missingEpochKey] gets. Distinct from [missingEpochKey] (device holds no key
  /// at all) and from [keyEpochStale]/`key_epoch_below_floor` (the authoring-side
  /// floor): this one is "the key may be held, but no applied `rotate` has
  /// established the epoch." Its healer is the **floor rising**, not the key
  /// arriving, so it carries its own floor-keyed release scan rather than
  /// [missingEpochKey]'s key-gated one.
  ///
  /// Client-only and stateful: the same envelope is future-epoch for one device
  /// and applicable for another that has applied the `rotate`, so it carries no
  /// golden vector.
  keyEpochUnknown('key_epoch_unknown'),

  /// A *content* op at suite 0x00 whose `key_epoch` this device holds a key for.
  ///
  /// The read-boundary half of "the upgrade is one-way": once an epoch is keyed,
  /// a coerced or buggy author cannot quietly hand the Workspace back a plaintext
  /// op at that epoch. History written at *earlier*, unkeyed epochs stays readable
  /// for ever — turn-on mints `K_{w,N+1}`, never `K_{w,N}` — which is what makes
  /// this the only dual-read branch the design needs.
  ///
  /// **Scoped to the content-carrying classes**, which since #555 means content
  /// *and* compaction — see [plaintextRefusedAtKeyedEpochOpClasses]. Control and
  /// prune are exempt in the opposite direction: they are 0x00 for ever by rule,
  /// so refusing a plaintext one would make them unauthorable.
  ///
  /// An alarm as well as a quarantine: unlike [missingEpochKey] nothing about this
  /// heals by waiting.
  plaintextAtEncryptedEpoch('plaintext_at_encrypted_epoch'),

  /// A KeyWrap or escrow wrap of the wrong length. A pure width check, refused
  /// before any crypto runs — see `key_wraps.dart`.
  malformedKeyWrap('malformed_keywrap'),

  /// A rotation would leave a live Grant with no wrap, so the ceremony refused
  /// **before authoring anything** (review F14a).
  ///
  /// Authoring-side only, and deliberately not stageable: a rotation whose wrap set
  /// omits a survivor would lock an honest Member out of the Workspace for ever, and
  /// the digest means the omission would be committed to in a signed op before
  /// anyone noticed. A blocked ceremony that says who it cannot wrap to is the
  /// recoverable outcome; a staged one is not.
  ///
  /// The reachable case today is a live-granted **Service**: Services hold no
  /// per-User KEX subkey yet (that rides #557), so a Workspace with one cannot
  /// rotate until it does. A Device is always wrappable — a Grant to a Member this
  /// device has not chained is already refused as `unknown_grantee`, so every
  /// surviving Device in the grants view is in the directory with its KEX key.
  unwrappableGrant('unwrappable_grant'),

  /// A content op built against a `key_epoch` the server has already rotated past
  /// by more than one. The authoring-side twin of the server's `key_epoch_stale`
  /// refusal, so a device does not post what it will only be handed back.
  keyEpochStale('key_epoch_stale'),

  /// No *verified* MemberRegister has taught this device the author's key.
  ///
  /// Replaces the pre-#548 `unknown_author_key`, which meant "not in the
  /// registry the server served us". A registry miss and a chain miss are
  /// different claims: this one says nothing signed by Root vouches for the
  /// author, whatever the server's registry says.
  memberNotChainedToRoot('member_not_chained_to_root'),

  /// A Root signature that does not verify — over a registration, or over a
  /// genesis, under that document's own domain.
  ///
  /// A claim strictly *about the signature*. Kept for the case where the bytes
  /// really are unsigned or tampered with; the genesis root-pk cross-check no
  /// longer lands here (see [certRootPkMismatch]).
  badRootSignature('bad_root_signature'),

  /// A Root-signed certificate that is *about* a different member than the
  /// envelope wearing it. Distinct from [badRootSignature] because nothing is
  /// wrong with the signature: a genuine certificate is public the moment it is
  /// in the log, and this is somebody wrapping a copy around their own envelopes.
  /// The same code the server returns at 422.
  certMemberMismatch('cert_member_mismatch'),

  /// The certificate's key is not the one the header names — on the server, not
  /// the member's registered key. Separate from [certMemberMismatch] because the
  /// certificate names the right member and only the key disagrees, which is a
  /// different attack with a different remediation (ADR-0032).
  certKeyMismatch('cert_key_mismatch'),

  /// The Root embedded in a signed genesis is not the Root this device pinned.
  ///
  /// Distinct from [badRootSignature] because the Root signature *verified*: the
  /// genesis is genuinely signed over exactly these bytes, and what disagrees is
  /// the `root_pk` inside the signed document. That is the whole reason `root_pk`
  /// is in there — a verifier can only cross-check a Root it can see. Saying
  /// `bad_root_signature` here would accuse a signature nothing is wrong with,
  /// destroying a distinction a skewed Device cannot recover (ADR-0039). The
  /// same code the server returns at 422.
  certRootPkMismatch('cert_root_pk_mismatch'),

  /// A Root-signed certificate or statement names a Workspace this device did
  /// not pull from.
  ///
  /// Separate from [workspaceMismatch], which is the *header* check: a header
  /// naming another Workspace accuses the server of serving the wrong log, while
  /// a signed document naming one is a forged document that survived its own
  /// signature check. Two accusations, two remediations — and a Quarantine row is
  /// the one surface that has to tell them apart with no server to ask. The same
  /// code the server returns at 422.
  certWorkspaceMismatch('cert_workspace_mismatch'),

  /// A Grant's granter did not sign it, under the Grant's own domain.
  badGrantSignature('bad_grant_signature'),

  /// A Revoke's revoker did not sign it, under the Revoke's own domain.
  badRevokeSignature('bad_revoke_signature'),

  /// A Grant or Revoke certificate names a different granter/revoker than the
  /// payload's `authority` field, or nominates an authority the envelope's
  /// author does not hold.
  ///
  /// Distinct from [badGrantSignature]/[badRevokeSignature] because no signature
  /// is being accused: authority rides in the signed certificate bytes, and the
  /// payload field only says which key to check them against. A disagreement
  /// between the two is a forgery attempt, not a broken signature. One code
  /// covers both sides because the server does not split them either — the
  /// granting and unmaking halves share `cert_granter_mismatch` at 422, so
  /// neither may a client.
  certGranterMismatch('cert_granter_mismatch'),

  /// A role outside owner/participant/compactor/suggester. Fails closed: a role
  /// a verifier cannot interpret is never read as a permissive default.
  unknownRole('unknown_role'),

  /// An `owner` Grant minted by anything but Root — a pure document invariant,
  /// so it is refused at decode wherever the bytes are held (ADR-0031).
  ownerGrantRequiresRoot('owner_grant_requires_root'),

  /// An `owner` Grant revoked by anything but Root. Needs the target Grant's
  /// role, so unlike its mint counterpart this one is a *stateful* verdict.
  ownerRevokeRequiresRoot('owner_revoke_requires_root'),

  /// A Grant naming a grantee this device cannot resolve. Fail-closed: never held
  /// as a dangling forward reference.
  unknownGrantee('unknown_grantee'),

  /// A Revoke naming a Grant this device cannot resolve. Distinct from
  /// [unknownGrantee] because a Revoke names a `grant_id`: conflating the two
  /// leaves a client unable to tell a failed revocation from an invalid grantee.
  unknownGrant('unknown_grant'),

  /// A Grant to a non-Device member in the `user_preferences` Workspace — the
  /// client-side half of "every Device, no Service ever".
  serviceGrantForbidden('service_grant_forbidden'),

  /// The author of a content op holds no Grant permitting its `op_class` at the
  /// op's own server seq. Logged-but-refused: the row is written and advances
  /// per-author accounting, and the payload never applies.
  noLiveGrant('no_live_grant'),

  /// A content op built against a `key_epoch` below the Workspace's persisted
  /// monotone floor. Authoring-side today; #554's rotate ops raise the floor.
  keyEpochBelowFloor('key_epoch_below_floor'),
  malformedControlPayload('malformed_control_payload'),
  unsupportedControlType('unsupported_control_type'),

  /// The control chain skipped or restarted under our feet — including the
  /// genesis-only zero-link rule in both directions. A positional break is
  /// re-examined once the named predecessor is applied; a shape break is
  /// permanent.
  controlChainBreak('control_chain_break'),

  /// Two control ops name the same predecessor. The tie-break picks a winner and
  /// this quarantines the losing branch, and everything chaining through it.
  controlChainFork('control_chain_fork'),
  unrepresentableAuthorSeq('unrepresentable_author_seq'),
  malformedPayload('malformed_payload'),
  malformedMemberIdHex('malformed_member_id_hex'),

  // --- Compaction and prune payload shape (#555) ----------------------------
  //
  // Payload-semantics verdicts, identical on every device, so each carries a
  // golden vector. Enforced between decode and apply on receive *and* before
  // anything is signed at authoring: one rule, both sides of that boundary.

  /// A class-4 field carrying no clock of its own.
  ///
  /// It would be stamped with the compactor's op-level clock and win merges the op
  /// it supersedes would have lost — the exact bug entity-level compaction must
  /// not have. An HLC names its author, so a field's own clock *is* its authorship
  /// provenance, and a class-4 field without one has thrown that away.
  compactionFieldWithoutHlc('compaction_field_without_hlc'),

  /// A class-4 tombstone with no `tombstone_hlc`. Re-stamping it with the
  /// compactor's newer clock would bury a resurrection the original could never
  /// have buried.
  compactionTombstoneWithoutHlc('compaction_tombstone_without_hlc'),

  /// `tombstone_hlc` on anything but a compaction op. Refused rather than
  /// ignored: a permitted-and-ignored field is one a future reader may start
  /// honouring, and two codecs disagreeing about whether it counts is a
  /// convergence bug.
  tombstoneHlcOutsideCompaction('tombstone_hlc_outside_compaction'),

  malformedPrunePayload('malformed_prune_payload'),

  /// A prune that attests nothing: it materialises nothing and can only exist to
  /// spend a chain slot or confuse an audit.
  pruneTargetsEmpty('prune_targets_empty'),

  /// Two targets sharing a `seq` **or** an `(author, author_seq)` position.
  /// Refused at decode, which is what leaves the server's materialisation
  /// rowcount check exactly one possible cause — a concurrent prune.
  pruneDuplicateTarget('prune_duplicate_target'),

  pruneTargetsTooMany('prune_targets_too_many'),

  /// An attestation and this device's own evidence disagree about the bytes at one
  /// position.
  ///
  /// Both bear real signatures — a gap-reason quarantine row exists only after
  /// `verifyEnvelope` passed — so either the author forked its own chain or the
  /// compactor attested a fabrication. An accusation, never a heal, and
  /// client-only: it needs the receiver's own log to detect, so it carries no
  /// golden vector.
  pruneAttestationDivergence('prune_attestation_divergence'),
  hlcInTheFuture('hlc_in_the_future'),
  hlcMemberIsNotAuthor('hlc_member_is_not_author'),

  /// A `user_preferences` op carrying `value` whose `key` is missing or not a
  /// string.
  ///
  /// Strategy selection for `user_preferences.value` is per-op by design
  /// (ADR-0033): the key names which lattice arbitrates the field, and the
  /// writer always has it — the entity id is derived from it. An op that carries
  /// a value without a resolvable key is therefore ambiguous about *which*
  /// merge strategy decides it, and it is refused rather than defaulted, because
  /// the default (LWW) was precisely the order-dependence: which strategy
  /// arbitrated depended on whether this device had already learned the key.
  ///
  /// Like the two HLC guards above — and unlike the client-only chain rules
  /// below — this is a payload-semantics verdict identical on every device, so
  /// it carries a golden vector (`user_preferences_value_without_key_is_refused`
  /// in `spec/sync/reducer_v1_vectors.json`).
  preferenceValueWithoutKey('preference_value_without_key'),

  /// A change whose `collection` belongs to a **different Workspace** than the
  /// log that carries it.
  ///
  /// Each Workspace's log carries only its own collections: `user_preferences`
  /// belongs to the preferences Workspace and every other collection to the
  /// default one. A change that crosses that line is refused on every Device,
  /// whichever Workspace's log carried it — the refusal is about the *pairing*
  /// of a collection and a log, so it holds in both directions.
  ///
  /// **Stateless, identical on every device, and pinned by a golden vector.**
  /// The verdict reads the collection and the receiving Workspace's identity,
  /// and nothing else — not the stored state, not what this device has already
  /// applied — so it is the payload-semantics class rather than a per-author
  /// chain rule, and it carries a vector
  /// (`user_preferences_change_in_the_default_workspace_log_is_refused` and its
  /// mirror in `spec/sync/reducer_v1_vectors.json`).
  ///
  /// Logged-but-refused like [preferenceValueWithoutKey]: the envelope stays in
  /// the op log as evidence with this code stamped, nothing reaches merge state
  /// or the domain tables, and the author's chain accounting advances — so the
  /// author's next honest change still applies.
  collectionOutsideWorkspace('collection_outside_workspace'),

  // --- Per-author chain rules (client-only) ---------------------------------
  //
  // These six are *stateful receiver policy*, not per-envelope codec rules: the
  // same envelope is chain-valid for one device and a gap for another, depending
  // on what each has already received. The server never quarantines and the
  // Python codec has no chain state, so — unlike every code above — these carry
  // no golden vector and no backend twin. See `chain_verifier.dart`.

  /// `author_seq` is beyond the verified head + 1.
  authorChainGap('author_chain_gap'),

  /// Right position, wrong `prev_author_hash`.
  prevAuthorHashMismatch('prev_author_hash_mismatch'),

  /// A position already held, served with different bytes.
  authorChainRewrite('author_chain_rewrite'),

  /// The same `(author, op_id)` under a different position or different bytes.
  duplicateOpIdDivergence('duplicate_op_id_divergence'),

  /// A pull served an op at or below the cursor, in a slot this device does not
  /// already hold byte-identically.
  staleReplayedOp('stale_replayed_op'),

  /// An envelope this device authored, served back with different bytes than the
  /// outbox row it was signed into. The local copy stands.
  ownWritesDivergence('own_writes_divergence'),

  /// A receive-path failure that was not itself a [SyncRejection] — a parse,
  /// verify or decode path throwing something unclassified.
  ///
  /// Client-only, and the backstop that makes "fail closed" total rather than
  /// best-effort: without it an adversarial envelope whose error escapes the
  /// pipeline would leave the cursor pinned, so every subsequent `pull()`
  /// refetches and throws on the same op for ever. Quarantining under this code
  /// keeps the op unapplied and surfaced while the stream continues.
  unexpectedReceiveFailure('unexpected_receive_failure');

  const SyncRejectionReason(this.code);

  /// The stable machine code written into the quarantine row and the vectors.
  final String code;

  static SyncRejectionReason byCode(String code) =>
      SyncRejectionReason.values.firstWhere((reason) => reason.code == code);
}

/// A fail-closed refusal: the op is never applied, always surfaced.
class SyncRejection implements Exception {
  const SyncRejection(this.reason, this.message);

  final SyncRejectionReason reason;
  final String message;

  @override
  String toString() => 'SyncRejection(${reason.code}): $message';
}
