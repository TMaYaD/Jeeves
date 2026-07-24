/// Cross-language determinism proof for the backfilled-Action id (ADR-0019).
///
/// The golden vector below is asserted byte-for-byte in the Python suite too
/// (backend/tests/test_actions_migration.py::test_backfill_id_golden_vector).
/// If either uuid5 implementation or the URI scheme drifts, one side fails —
/// which would break the dual-origin backfill convergence (issue #471).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/daos/action_ids.dart';

void main() {
  test('backfillActionIdFor matches the cross-language golden vector', () {
    const todoId = '00000000-0000-0000-0000-000000000001';
    expect(backfillActionIdFor(todoId), 'dfe9f9e7-e548-54dc-bb19-e13213ec2405');
  });

  test('backfillActionIdFor is deterministic and keyed on the Outcome', () {
    expect(backfillActionIdFor('a'), backfillActionIdFor('a'));
    expect(backfillActionIdFor('a'), isNot(backfillActionIdFor('b')));
  });
}
