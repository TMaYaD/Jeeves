/// `throwsRejection`, shared by every suite that asserts a fail-closed refusal.
///
/// Refusals are the sync stack's load-bearing behaviour, so they are asserted in
/// the codec suite, the harness suites and the author-side suites alike. One
/// definition means a case cannot pass because a file-local copy of the matcher
/// was laxer than its neighbour's.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';

/// Matches a thrown [SyncRejection], optionally pinned to one [reason].
///
/// Uses `isA<SyncRejection>().having(...)` rather than a bare `predicate`, so a
/// wrong-reason mismatch reports the actual [SyncRejectionReason] it saw
/// instead of collapsing to an opaque "does not match" line.
Matcher throwsRejection([SyncRejectionReason? reason]) => throwsA(
      reason == null
          ? isA<SyncRejection>()
          : isA<SyncRejection>().having(
              (error) => error.reason,
              'reason',
              reason,
            ),
    );
