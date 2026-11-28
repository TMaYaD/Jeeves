/// The fold behind the sync-health screen: the store's rows become the
/// conditions the screen renders.
///
/// A pure function over the two tables' rows, so the mapping the screen depends
/// on is exercised without a live Drift `watch()` under a widget.
///
/// The rule this file pins down is the one a refused row's **decision** hangs
/// on: a refused row whose change the log has applied has nothing left to
/// decide, and offering it a decision is a decision the store would refuse. So
/// the rows wait for the applied set before they are shown at all — a row
/// whose change is in must never appear carrying a button.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/alarm_resolution.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_health_detail.dart';

const String _breakCode = 'control_chain_break';

/// A refused row of the shape the fold reads.
QuarantineRow _refusedRow({int id = 7}) =>
    QuarantineRow(
      id: id,
      workspaceId: 'workspace-1',
      seq: 3,
      reason: _breakCode,
      detail: 'a control op named a predecessor this device had not applied',
      envelope: Uint8List.fromList(List<int>.filled(8, 1)),
      detectedAt: DateTime.utc(2026, 8, 1),
      authorMemberId: 'member-1',
      authorSeq: 1,
      releasedAt: null,
      releaseStartedAt: null,
      resolution: null,
      resolutionDecidedAt: null,
      resolutionProjectedAt: null,
    );

void main() {
  group('the refused rows', () {
    test('wait for the applied set before they are shown', () {
      // The set is not known yet: the rows are withheld rather than shown
      // carrying a decision that may not be theirs to offer.
      expect(
        syncHealthConditionsFor(
          workspaceId: 'workspace-1',
          alarms: const [],
          refusals: [_refusedRow()],
          appliedRefusalRowIds: null,
        ),
        isEmpty,
      );
    });

    test('a row whose change the log has applied offers no decision', () {
      final conditions = syncHealthConditionsFor(
        workspaceId: 'workspace-1',
        alarms: const [],
        refusals: [_refusedRow()],
        appliedRefusalRowIds: {7},
      );
      expect(conditions, hasLength(1));
      expect(conditions.single.resolutions, isEmpty,
          reason: 'the change is in, so there is nothing left to decide');
      expect(conditions.single.reAdmitted, isFalse);
    });

    test('a row that is still held may be refused for good', () {
      final conditions = syncHealthConditionsFor(
        workspaceId: 'workspace-1',
        alarms: const [],
        refusals: [_refusedRow()],
      );
      expect(conditions, hasLength(1));
      expect(conditions.single.resolutions, [AlarmResolution.rejectedPermanently]);
    });
  });
}
