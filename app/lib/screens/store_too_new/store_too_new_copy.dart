/// Every word the too-new-store screen puts in front of a user, and nothing
/// else.
///
/// **Plain voice, no Jeeves register.** This is where a user lands after
/// putting back an older build, holding data they believe is safe. The screen
/// has two jobs — say that the data belongs to a newer Jeeves, and say that
/// nothing was changed — and both are said without a word of the code's
/// vocabulary. `store_too_new_copy_test.dart` holds the sentences against the
/// banned words, because that is the rule that decays first.
///
/// Pure Dart, no Flutter import: the sentences are asserted without pumping a
/// widget.
library;

/// The screen's title.
const String storeTooNewTitle = 'Your data needs a newer Jeeves';

/// What happened.
///
/// Four sentences, one idea each: the data was used by a newer Jeeves; this
/// version cannot read it; nothing was changed; nothing was deleted. The last
/// two are the point of the screen — a user who opens an older build and finds
/// their data gone has lost the one thing they cannot get back.
const String storeTooNewExplanation =
    'The data on this phone was last used by a newer version of Jeeves. '
    'This version of Jeeves cannot read that data. '
    'Nothing was changed. Nothing was deleted.';

/// What to do about it.
const String storeTooNewAdvice =
    'Install the newest version of Jeeves to open your data again.';

/// The running build's own version, so a user can tell which build they are
/// looking at.
const String storeTooNewRunningVersionLabel = 'Running version: ';

/// The words of the code that must never reach this screen.
///
/// A user who has just put back an older build has a question about their
/// data, not about the storage layer. These are the words the storage layer
/// uses for itself: the two local stores, the schema they carry, the rows in
/// them. None of them is the user's word, and every one of them has appeared
/// in a first draft of a screen like this.
const List<String> storeTooNewBannedWords = [
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
const List<String> storeTooNewBannedVoiceMarkers = [
  'i',
  'me',
  'my',
  'sir',
];
