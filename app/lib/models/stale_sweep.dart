/// Preference key and default for the Stale sweep threshold: how many
/// FocusSessions must have passed an Outcome over before it is Stale
/// (CONTEXT.md § Engagement, Stale).
library;

const String kStaleSweepThresholdPrefKey = 'stale_sweep_threshold';
const int kDefaultStaleSweepThreshold = 3;

/// The threshold choices Settings offers.
const List<int> kStaleSweepThresholdOptions = [2, 3, 4, 5, 7, 10];

/// What the user decided for a Stale Outcome. The names are the values stored
/// in `outcome_sweep_decisions.decision`.
enum StaleSweepDecision { maybe, trash }
