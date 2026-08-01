/// Leaving the sync-health screen while it is still loading.
///
/// `syncHealthDetailProvider` is an async generator with three `await` points
/// before it owns anything worth releasing, and **Riverpod does not cancel a
/// suspended generator on dispose** — the body resumes regardless. Two things
/// follow, and both are what these tests pin:
///
/// * The disposal hook has to be registered *before* the first await. Registered
///   after, it runs against a dead `ref` and throws, so the Drift watches the
///   body just opened are never cancelled and the controller is never closed:
///   two live subscriptions per Workspace, leaked on every open-and-close of a
///   screen the user did not wait for.
/// * The body has to stop at each await rather than carry on. `ref` is unusable
///   once the element is gone, so a resumed body that reaches the next
///   `ref.watch` throws out of the generator instead of returning quietly.
///
/// The witness in both cases is that **nothing escapes**: the zone collects
/// every uncaught async error, and either failure announces itself as the
/// `UnmountedRefException` Riverpod raises for a `ref` used after disposal.
/// Reverting either half of the guard turns both tests red.
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
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
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import '../sync/harness/fake_sync_server.dart';
import '../sync/harness/sim_device.dart' show DeviceLink, harnessKdfParameters;
import '../test_helpers.dart';

const String _userId = 'health-detail-user';
const int _nowMs = 1770000000000;

class _SignedInAs extends CurrentUserIdNotifier {
  @override
  String build() => _userId;
}

/// Drain the real event loop until every pending microtask and timer has run.
Future<void> _settle() async {
  for (var round = 0; round < 4; round++) {
    await Future<void>.delayed(Duration.zero);
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

  Future<SyncStack> buildStack() => SyncStack.assemble(
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

  /// Run [body] with every uncaught async error collected rather than reported.
  Future<List<Object>> errorsDuring(Future<void> Function() body) async {
    final errors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      await body();
      done.complete();
    }, (error, _) => errors.add(error));
    await done.future;
    await _settle();
    return errors;
  }

  test('disposed while the lifecycle is still in flight: nothing is touched '
      'afterwards', () async {
    final lifecycle = Completer<SyncLifecycle?>();
    var stackBuilds = 0;

    final errors = await errorsDuring(() async {
      final container = ProviderContainer(overrides: [
        currentUserIdProvider.overrideWith(_SignedInAs.new),
        syncLifecycleProvider.overrideWith((ref) => lifecycle.future),
        syncStackProvider.overrideWith((ref) async {
          stackBuilds++;
          return buildStack();
        }),
      ]);
      container.listen(syncHealthDetailProvider, (_, _) {});
      await _settle();

      // The user leaves before the lifecycle has answered.
      container.dispose();
      lifecycle.complete(null);
      await _settle();
    });

    expect(errors, isEmpty, reason: 'the resumed body used a disposed ref');
    expect(
      stackBuilds,
      0,
      reason: 'the body carried on reading providers after it was disposed',
    );
  });

  test('disposed while the stack is still assembling: no watch is opened',
      () async {
    final pendingStack = Completer<SyncStack>();

    final errors = await errorsDuring(() async {
      final container = ProviderContainer(overrides: [
        currentUserIdProvider.overrideWith(_SignedInAs.new),
        syncLifecycleProvider.overrideWith((ref) async => null),
        syncStackProvider.overrideWith((ref) => pendingStack.future),
      ]);
      container.listen(syncHealthDetailProvider, (_, _) {});
      await _settle();

      // Past the first await, suspended on the second: the point at which the
      // original ordering had already committed to opening subscriptions it
      // would then fail to register a hook for.
      container.dispose();
      pendingStack.complete(await buildStack());
      await _settle();
    });

    expect(errors, isEmpty, reason: 'the resumed body used a disposed ref');
  });
}
