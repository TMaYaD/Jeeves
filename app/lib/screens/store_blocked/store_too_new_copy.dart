/// The words for the case the data on the phone was written by a newer
/// Jeeves.
///
/// Four sentences, one idea each: the data was used by a newer Jeeves; this
/// version cannot read it; nothing was changed; nothing was deleted. The last
/// two are the point of the screen — a user who opens an older build and finds
/// their data gone has lost the one thing they cannot get back.
///
/// The rules these words obey are `store_blocked_copy.dart`'s.
library;

import 'store_blocked_copy.dart';

/// The words for a store written by a newer build.
const StoreBlockedCopy storeTooNewCopy = StoreBlockedCopy(
  title: 'Your data needs a newer Jeeves',
  explanation: 'The data on this phone was last used by a newer version of '
      'Jeeves. This version of Jeeves cannot read that data. '
      'Nothing was changed. Nothing was deleted.',
  advice: 'Install the newest version of Jeeves to open your data again.',
);
