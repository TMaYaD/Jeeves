/// Every word the blocking screen can put in front of a user, and the rules
/// those words obey.
///
/// **Plain voice, no Jeeves register.** This is where a user lands after
/// putting back an older build, holding data they believe is safe. The screen
/// has two jobs — say why the data is not on screen, and say that nothing was
/// changed — and both are said without a word of the code's vocabulary.
/// `store_blocked_copy_test.dart` holds the sentences against the banned
/// words, because that is the rule that decays first.
///
/// **There are two sets of sentences, one per reason the app cannot open the
/// stores.** The data was written by a newer Jeeves, or the data could not be
/// read at all. The second is not a flavour of the first — a file this build
/// cannot read may or may not be one a newer build wrote — so it gets its own
/// words and never borrows the first's.
///
/// Pure Dart, no Flutter import: the sentences are asserted without pumping a
/// widget.
library;

/// The words on the blocking screen.
class StoreBlockedCopy {
  const StoreBlockedCopy({
    required this.title,
    required this.explanation,
    required this.advice,
  });

  /// The screen's title.
  final String title;

  /// What happened.
  final String explanation;

  /// What to do about it.
  final String advice;
}

/// The running build's own version, so a user can tell which build they are
/// looking at.
const String storeBlockedRunningVersionLabel = 'Running version: ';

/// The words of the code that must never reach this screen.
///
/// A user who has just put back an older build has a question about their
/// data, not about the storage layer. These are the words the storage layer
/// uses for itself: the two local stores, the schema they carry, the rows in
/// them. None of them is the user's word, and every one of them has appeared
/// in a first draft of a screen like this.
const List<String> storeBlockedBannedWords = [
  'schema',
  'migration',
  'migrate',
  'database',
  'sqlite',
  'store',
  'stores',
  'read model',
  'op log',
  'table',
  'column',
  'row',
  'rows',
  'user_version',
  'build',
  'instance',
  'checkpoint',
  'write-ahead',
  'wal',
];

/// First-person and address markers of the Jeeves register, which this screen
/// deliberately opts out of, exactly as the sync-health surface does.
const List<String> storeBlockedBannedVoiceMarkers = [
  'i',
  'me',
  'my',
  'sir',
];
