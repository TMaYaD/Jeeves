/// Preference key and default for the Bypassed threshold: how many
/// FocusSessions must have passed an Outcome over before it is Bypassed
/// (CONTEXT.md § Engagement, Bypassed).
library;

const String kBypassThresholdPrefKey = 'bypass_threshold';
const int kDefaultBypassThreshold = 3;

/// The threshold choices Settings offers.
const List<int> kBypassThresholdOptions = [2, 3, 4, 5, 7, 10];

/// What the user decided for a Bypassed Outcome. The names are the values stored
/// in `outcome_bypass_decisions.decision`.
enum BypassDecision { maybe, trash }
