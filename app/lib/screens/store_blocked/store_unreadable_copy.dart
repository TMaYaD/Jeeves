/// The words for the case the data on the phone could not be read at all.
///
/// **This is not the too-new case in another coat.** A file this build cannot
/// open says nothing about the schema it carries: it may be a store a newer
/// build wrote, and this build would not know. The screen therefore says what
/// actually happened — the data could not be read, so it was not opened — and
/// never claims the data belongs to a newer Jeeves, which nothing here knows.
///
/// It says the same two things the too-new screen says, because they hold
/// here too: nothing was changed, and nothing was deleted.
///
/// The rules these words obey are `store_blocked_copy.dart`'s.
library;

import 'store_blocked_copy.dart';

/// The words for a store this build cannot read.
const StoreBlockedCopy storeUnreadableCopy = StoreBlockedCopy(
  title: 'Jeeves did not open your data',
  explanation: 'Jeeves could not read the data on this phone, so it did not '
      'open it. Nothing was changed. Nothing was deleted.',
  advice: 'Close Jeeves and open it again. If that does not help, install the '
      'newest version of Jeeves.',
);
