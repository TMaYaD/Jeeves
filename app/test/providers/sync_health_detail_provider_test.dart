/// The provider behind the sync-health screen: what the store's rows become,
/// and when they may be shown.
///
/// **A refused row whose change the log has applied offers no decision**, and
/// the store would refuse that decision if it were offered. The applied set is
/// what says so, and it arrives on its own watch, so the refused rows wait for
/// it: a row that may turn out to be in must never appear carrying a button.
///
/// The witness is every emission the provider makes: none of them may offer a
/// decision for a row whose change the log has applied — not the first, not any
/// later one.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/sync_health_detail_provider.dart';
import 'package:jeeves/providers/sync_lifecycle_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/pending_rotation_store.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_health_detail.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import '../sync/harness/fake_sync_server.dart';
import '../sync/harness/sim_device.dart' show DeviceLink, harnessKdfParameters;
import '../test_helpers.dart';

const String _userId = 'health-detail-user';
const int _nowMs = 1770000000000;
const String _breakCode = 'control_chain_break';

class _SignedInAs extends CurrentUserIdNotifier {
  @override
  String build() => _userId;
}

/// Wait for [ready], so a watch that has not delivered yet is not read as one
/// that never will.
Future<void> _waitFor(bool Function() ready) async {
  for (var round = 0; round < 200 && !ready(); round++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late SyncDatabase database;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
  });

  test('a refused row whose change is applied never offers a decision',
      () async {
    final stack = await SyncStack.assemble(
      userId: _userId,
      database: database,
      keyStore: InMemoryDeviceKeyStore(),
      userTransport: DeviceLink(FakeSyncServer().connectAsUser(_userId)),
      workspaceKeys: InMemoryWorkspaceKeyStore(),
      pendingRotations: InMemoryPendingRotationStore(),
      kdfParameters: harnessKdfParameters,
      kdfFloor: harnessKdfParameters,
      nowMs: () => _nowMs,
    );
    final workspaceId = stack.defaultClient.workspaceId;

    // A refused row whose change the log has since applied: the change
    // arrived out of order, and the row is the evidence of it.
    final envelope = Uint8List.fromList(List<int>.filled(8, 7));
    final rowId = await database.into(database.quarantinedOps).insert(
          QuarantinedOpsCompanion.insert(
            workspaceId: workspaceId,
            seq: const Value(3),
            reason: _breakCode,
            detail: 'a control op named a predecessor this device had not '
                'applied',
            envelope: envelope,
            detectedAt: DateTime.utc(2026, 8, 1),
            authorMemberId: const Value('member-1'),
            authorSeq: const Value(1),
          ),
        );
    await database.into(database.opLog).insert(
          OpLogCompanion.insert(
            seq: 3,
            workspaceId: workspaceId,
            envelope: envelope,
            opId: 'op-1',
            authorMemberId: 'member-1',
            authorSeq: 1,
            receivedAt: DateTime.utc(2026, 8, 1),
            appliedAt: Value(DateTime.utc(2026, 8, 1)),
          ),
        );

    final seen = <List<SyncHealthCondition>>[];
    final container = ProviderContainer(overrides: [
      currentUserIdProvider.overrideWith(_SignedInAs.new),
      syncLifecycleProvider.overrideWith((ref) async => null),
      syncStackProvider.overrideWith((ref) async => stack),
    ]);
    addTearDown(container.dispose);
    container.listen(syncHealthDetailProvider, (_, next) {
      final value = next.asData?.value;
      if (value != null) seen.add(value);
    });

    await _waitFor(() => seen.any((conditions) => conditions.any(
          (condition) => condition.source == SyncConditionSource.refusedItem,
        )));
    expect(seen, isNotEmpty, reason: 'the provider emitted nothing');
    // A moment more, so a later emission is read too.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // No emission may offer a decision for a row whose change is in.
    for (final conditions in seen) {
      for (final condition in conditions.where(
        (condition) => condition.source == SyncConditionSource.refusedItem,
      )) {
        expect(condition.rowId, rowId);
        expect(
          condition.resolutions,
          isEmpty,
          reason: 'the change is in, so there is nothing left to decide',
        );
      }
    }

    // And the row does arrive: the wait is not the row's permanent state.
    final last = seen.last.where(
      (condition) => condition.source == SyncConditionSource.refusedItem,
    );
    expect(last, hasLength(1));
    expect(last.single.resolutions, isEmpty);
  });
}
