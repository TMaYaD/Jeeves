/// Every word the sync-health surface puts in front of a user, and nothing else.
///
/// **Copy only — no classification.** What class a stored code belongs to is
/// domain state and lives in `sync/sync_condition_class.dart`; this file answers
/// only what to *call* it, keyed by the same stored code. Keeping the two apart
/// is what lets the sync tier classify a condition without importing a screen,
/// which is the direction `CONTEXT.md` prescribes and the reverse of what
/// shipped first.
///
/// **Plain voice. No Jeeves register anywhere on this surface**, deliberately and
/// as a recorded rule (`docs/DESIGN.md` § Sync health). This is where a user
/// lands when they suspect something is broken; character in that moment reads
/// as evasive, and a valet's understatement about data the user is worried about
/// is the wrong instrument.
///
/// **The vocabulary is the user's.** They have Tasks, lists, devices; they
/// edited something, finished something, deleted something. They do not have
/// ops, envelopes, epochs, chains, attestations, quarantine, upstream, seqs,
/// author streams, Workspaces, prunes, HLCs, alarms or kinds — and are never
/// shown one. `sync_health_copy_test.dart` asserts the banned list against every
/// sentence here, because without it this decays the first time someone adds a
/// kind in a hurry.
///
/// **The device rule: name *this* device, or name a set, or name nobody — never
/// an anonymous singular peer.** "Another device" is uninformative exactly where
/// a name exists to be shown, so it is not written here at all and there is no
/// rejected string to retire when device naming (#669) lands. Holding the first
/// drafts against this rule caught two of them breaking it, which is why it is a
/// test rather than a paragraph.
///
/// Pure Dart, no Flutter import: the sentences are asserted without pumping a
/// widget.
library;

import '../../sync/chain_verifier.dart';
import '../../sync/ids.dart';
import '../../sync/sync_condition_class.dart';

/// The screen's own strings.
const String syncHealthScreenTitle = 'Sync';

/// Shown above the groups whenever nothing needs the user's attention. It is the
/// whole justification for a visible-but-calm indicator state: a user who has
/// never seen one needs the screen to tell them, in one plain sentence, that
/// this is worth reading and needs nothing from them.
const String syncHealthAllHandledExplanation =
    'Sync is working normally. These are things that happened along the way — '
    'none of them needs anything from you.';

const String syncHealthNeedsAttentionHeading = 'NEEDS ATTENTION';
const String syncHealthHandledHeading = 'HANDLED';

/// The tooltip on the calm indicator state. Same phrase as the state's name, so
/// the enum member, the tooltip and the explanation are one idea in three places.
const String syncHealthWorthKnowingTooltip = 'A few things worth knowing';

/// What the user is told about a stored alarm code.
///
/// An **exhaustive switch over the enum**, never a `Map` and never a `default`:
/// together with [classOfAlarmCode] it makes adding a kind without deciding both
/// what it is and what it says a compile error.
String sentenceForAlarmCode(String code) {
  final kind = integrityAlarmKindByCodeOrNull(code);
  if (kind == null) return syncHealthUnknownConditionSentence;
  return switch (kind) {
    // --- actionable -------------------------------------------------------
    IntegrityAlarmKind.authorChainGap =>
      'Some changes made on your other devices never reached this one.',
    IntegrityAlarmKind.ownWritesRollback =>
      "Changes you made on this device weren't saved to sync.",
    IntegrityAlarmKind.ownWriteRefusedPermanently =>
      "Something you did on this device can't be sent, and newer changes are "
          'stuck behind it.',
    IntegrityAlarmKind.epochKeySetUnpublishable =>
      "This device couldn't finish moving your data onto a new encryption key.",

    // --- reported ---------------------------------------------------------
    IntegrityAlarmKind.ownWritesDivergence =>
      'Sync had a different copy of something you changed here. '
          "This device's copy was kept.",
    IntegrityAlarmKind.authorStreamReordered =>
      'Some changes arrived out of order. They have all been applied.',
    IntegrityAlarmKind.stalePrefixServed =>
      'Sync re-sent changes this device had already received.',
    IntegrityAlarmKind.controlChainFork =>
      'Your sync setup was changed in two places at once. One change was kept.',
    IntegrityAlarmKind.authorChainSlotCollision =>
      "Sync sent two different changes in one slot. The second wasn't applied.",
    IntegrityAlarmKind.pruneAttestationDivergence =>
      "Sync's summary of older changes doesn't match what this device kept. "
          "This device's copy was kept.",
    IntegrityAlarmKind.prevAuthorHashMismatch =>
      "Some changes don't follow on from what this device already has, so they "
          "weren't applied.",
    IntegrityAlarmKind.authorChainRewrite =>
      'Sync sent a changed copy of something this device already had. '
          'The original was kept.',
    IntegrityAlarmKind.authorChainFork =>
      'Two conflicting changes claim the same place in your history. '
          'Only one was applied.',
    IntegrityAlarmKind.duplicateOpIdDivergence =>
      'The same change arrived twice with different contents. '
          'The first was kept.',
    IntegrityAlarmKind.signatureInvalid =>
      "Some changes couldn't be confirmed as coming from your devices, so they "
          "weren't applied.",
    IntegrityAlarmKind.aeadFailure =>
      "Some changes couldn't be unlocked with your encryption key, so they "
          "weren't applied.",
    IntegrityAlarmKind.plaintextAtEncryptedEpoch =>
      'Some changes arrived unprotected when they should have been encrypted, '
          "so they weren't applied.",
    IntegrityAlarmKind.noLiveGrant =>
      'Some changes were made with access that has since been removed, so they '
          "weren't applied.",
  };
}

/// What a code this build has never heard of is called.
///
/// A store written by a newer build can hold one, and the honest thing to say is
/// that we do not know rather than to crash or to hide the row.
const String syncHealthUnknownConditionSentence =
    "Sync reported something this version of the app doesn't recognise.";

/// What the user is told about a refused item's stored reason.
///
/// Most reasons carry an alarm kind, and where they do the alarm's sentence is
/// the one to use — the two describe the same event from either side, and a
/// second wording for it would be a second claim to keep true. The ~20 codec and
/// certificate reasons that raise no alarm share one sentence: the app could not
/// read the bytes, which is all the user needs and all we honestly know.
String sentenceForRefusalCode(String code) {
  final reason = syncRejectionReasonByCodeOrNull(code);
  if (reason == null) return syncHealthUnknownConditionSentence;
  final kind = alarmForRejection(reason);
  if (kind != null) return sentenceForAlarmCode(kind.code);
  return syncHealthUnreadableRefusalSentence;
}

const String syncHealthUnreadableRefusalSentence =
    "Some changes couldn't be read by this app, so they weren't applied.";

/// What to call one of the device's two Workspaces, in the user's own terms.
///
/// Null for an id this build does not recognise — a section with no honest label
/// shows no label at all, rather than a raw uuid.
String? syncWorkspaceLabelFor(String workspaceId, String userId) {
  if (workspaceId == defaultWorkspaceId(userId)) return 'TASKS AND LISTS';
  if (workspaceId == userPreferencesWorkspaceId(userId)) return 'SETTINGS';
  return null;
}

/// Vocabulary that must never reach this surface, asserted by test.
///
/// Matched as whole words, case-insensitively: "copy" contains "op" and is
/// perfectly good English.
const List<String> syncHealthBannedWords = [
  'op',
  'ops',
  'envelope',
  'envelopes',
  'epoch',
  'epochs',
  'chain',
  'chains',
  'attestation',
  'attestations',
  'quarantine',
  'quarantined',
  'upstream',
  // Both forms, because the match is by whole word: "seq" does not catch "seqs".
  'seq',
  'seqs',
  'author',
  'stream',
  'streams',
  'workspace',
  'workspaces',
  'prune',
  'pruned',
  'hlc',
  'alarm',
  'alarms',
  'kind',
  'kinds',
];

/// Phrasings that point at an unnamed single peer.
///
/// The author's rule is that "another device" is uninformative precisely where a
/// name exists to be shown. Naming *this* device needs no lookup, and naming a
/// set ("your other devices") makes no singular claim to be uninformative about
/// — so both stay, and only the anonymous singular is banned.
const List<String> syncHealthBannedDeviceReferences = [
  'another device',
  'one of your other devices',
  'a device that',
  'the other device',
  'a different device',
];

/// First-person and address markers of the Jeeves register, which this surface
/// deliberately opts out of.
const List<String> syncHealthBannedVoiceMarkers = [
  'i',
  'me',
  'my',
  'sir',
];
