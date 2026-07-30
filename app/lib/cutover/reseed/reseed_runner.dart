/// One reseed run, and the wiring that gives it a real device.
///
/// **Cutover tooling — removed by #556.**
///
/// [runReseed] is the whole ceremony with every dependency injected, so the run
/// under test is the run that happens on the phone: production hands in a read
/// over the **domain store**, the enrolled clients off `syncStackProvider` and
/// native scratch stores; a test hands in a seeded domain database, a
/// `SimDevice`'s clients and in-memory ones. There is no second code path.
///
/// The row source is `GtdDatabase` rather than PowerSync's own `getAll`: the
/// domain read model is what the initial upload walks, and reading it through the
/// domain store keeps this surface pointed at the same rows when #556 moves that
/// store off PowerSync's file.
///
/// The stage order is load-bearing in one place: **pull before authoring**. The
/// diff skip that makes a re-run safe compares against the new spine's reduced
/// state, so a device whose sync store was rebuilt has to have the log back
/// before it decides what is missing — otherwise it re-authors the entire store.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../../database/gtd_database.dart';
import '../../providers/database_provider.dart';
import '../../providers/powersync_provider.dart';
import '../../providers/sync_stack_provider.dart';
import '../../sync/ids.dart';
import '../../sync/initial_upload.dart';
import '../../sync/initial_upload_plan.dart';
import '../../sync/reducer.dart';
import '../../sync/sync_client.dart';
import '../../sync/sync_stack.dart';
import '../converge_verify/converge_differ.dart'
    show ReadOnlyProof, buildLocalConvergeReport;
import 'reseed_report.dart';
import 'reseed_scratch_store.dart';
import 'reseed_verifier.dart';

/// Where a run has got to, for the screen's stage list.
enum ReseedStage {
  checkingPreconditions,

  /// Flush and pull both Workspaces, so the diff skip sees the real log.
  pulling,

  planning,
  authoring,

  /// Reduce the server log from zero on a throwaway stack, and compare.
  verifying,

  done,
}

/// A run's progress, in the two grains a screen shows: which stage, and how far
/// through the authoring walk.
class ReseedProgress {
  const ReseedProgress({required this.stage, this.upload});

  final ReseedStage stage;
  final InitialUploadProgress? upload;

  String get summaryLine => upload?.summaryLine ?? _stageLine;

  String get _stageLine => switch (stage) {
        ReseedStage.checkingPreconditions => 'Checking preconditions…',
        ReseedStage.pulling => 'Syncing both Workspaces before authoring…',
        ReseedStage.planning => 'Planning the reseed from the legacy store…',
        ReseedStage.authoring => 'Authoring ops…',
        ReseedStage.verifying =>
          'Reducing the server log from zero and comparing…',
        ReseedStage.done => 'Done.',
      };
}

/// Run the reseed: plan, author, flush, then verify against the server log.
Future<ReseedOutcome> runReseed({
  required InitialUploadRowSource readLegacyRows,
  required SyncClient gtdClient,
  required SyncClient preferencesClient,
  required ReducedCollectionReader readReducedCollection,
  required ReseedScratchStackFactory buildScratchStack,
  required Future<int?> Function() powerSyncUploadQueueCount,
  required String Function() mintTagId,
  void Function(ReseedProgress)? onProgress,
  int flushEveryOpCount = initialUploadFlushEveryOpCount,
}) async {
  void report(ReseedStage stage, [InitialUploadProgress? upload]) =>
      onProgress?.call(ReseedProgress(stage: stage, upload: upload));

  report(ReseedStage.checkingPreconditions);
  // Both snapshots bracket everything the run does, so the proof covers the
  // authoring and the verification too, not just the planning read.
  final queueBefore = await powerSyncUploadQueueCount();
  final legacyDigestBefore =
      (await buildLocalConvergeReport(readLegacyRows)).digest;

  final enrolled = gtdClient.isEnrolled && preferencesClient.isEnrolled;
  // Both Workspaces, because both get a scratch stack: an enrolment that crashed
  // between the two pins leaves a device that can author into GTD and then cannot
  // verify preferences at all. That has to read as the precondition it is, not as
  // an uncaught error thrown after the authoring already happened.
  final rootPinned = await gtdClient.pinnedRootPk() != null &&
      await preferencesClient.pinnedRootPk() != null;

  var pulledBeforeAuthoring = false;
  if (enrolled && rootPinned) {
    report(ReseedStage.pulling);
    await gtdClient.sync();
    await preferencesClient.sync();
    pulledBeforeAuthoring = true;
  }

  report(ReseedStage.planning);
  final plan = await buildInitialUploadPlan(
    readLegacyRows: readLegacyRows,
    userId: gtdClient.userId,
    preferencesWorkspaceId: preferencesClient.workspaceId,
    mintTagId: mintTagId,
    spineLabelTagsByName: pulledBeforeAuthoring
        ? await readSpineLabelTags(readReducedCollection)
        : const {},
  );

  InitialUploadReport? upload;
  final tables = <ReseedTableDiff>[];
  var pendingOpCount = 0;

  if (pulledBeforeAuthoring) {
    report(ReseedStage.authoring);
    upload = await runInitialUpload(
      plan: plan,
      gtdClient: gtdClient,
      preferencesClient: preferencesClient,
      readReducedCollection: readReducedCollection,
      flushEveryOpCount: flushEveryOpCount,
      onProgress: (progress) => report(ReseedStage.authoring, progress),
    );
    pendingOpCount = (await gtdClient.health()).pendingOpCount +
        (await preferencesClient.health()).pendingOpCount;

    report(ReseedStage.verifying);
    for (final workspace in InitialUploadWorkspace.values) {
      final live = workspace == InitialUploadWorkspace.preferences
          ? preferencesClient
          : gtdClient;
      final stack = await buildScratchStack(live.workspaceId);
      try {
        // From cursor 0: the whole log, through the whole receive pipeline.
        await stack.client.pull();
        tables.addAll(await compareReducedStateWithPlan(
          plan: plan,
          stack: stack,
          collections: reseedCollectionsFor(workspace),
        ));
      } finally {
        await stack.close();
      }
    }
  }

  final legacyDigestAfter =
      (await buildLocalConvergeReport(readLegacyRows)).digest;
  final queueAfter = await powerSyncUploadQueueCount();
  final readOnlyProof = ReadOnlyProof(
    localDigestBefore: legacyDigestBefore,
    localDigestAfter: legacyDigestAfter,
    uploadQueueCountBefore: queueBefore,
    uploadQueueCountAfter: queueAfter,
  );
  final preconditions = ReseedPreconditions(
    enrolled: enrolled,
    rootPinned: rootPinned,
    pulledBeforeAuthoring: pulledBeforeAuthoring,
    pendingOpCountAfterFlush: pendingOpCount,
  );

  // The tables are collected per Workspace; the report reads in the one order
  // the rest of this library uses.
  tables.sort((a, b) => initialUploadCollectionOrder
      .indexOf(a.table)
      .compareTo(initialUploadCollectionOrder.indexOf(b.table)));

  report(ReseedStage.done);
  return ReseedOutcome(
    verdict: reseedVerdictFor(
      preconditions: preconditions,
      readOnlyProof: readOnlyProof,
      plan: plan,
      tables: tables,
    ),
    plan: plan,
    upload: upload,
    tables: tables,
    readOnlyProof: readOnlyProof,
    preconditions: preconditions,
  );
}

// --- production wiring ------------------------------------------------------

abstract class ReseedRunner {
  Future<ReseedOutcome> run({void Function(ReseedProgress)? onProgress});
}

class RiverpodReseedRunner implements ReseedRunner {
  RiverpodReseedRunner(this._ref);

  final Ref _ref;

  Future<ps.PowerSyncDatabase> get _powerSync =>
      _ref.read(powerSyncInstanceProvider.future);

  Future<SyncStack> get _stack => _ref.read(syncStackProvider.future);

  /// Unfiltered on purpose (#582's rule): a row stranded at `user_id = 'local'`
  /// has to reach the plan and the report, not vanish behind a predicate.
  ///
  /// SELECTs only — this is the read-only half, and the proof in the report is
  /// the evidence rather than this comment.
  Future<List<Map<String, Object?>>> _readLegacyRows(String table) async {
    final rows =
        await _ref.read(databaseProvider).customSelect('SELECT * FROM $table').get();
    return [for (final row in rows) Map<String, Object?>.of(row.data)];
  }

  Future<int?> _uploadQueueCount() async =>
      (await (await _powerSync).getUploadQueueStats()).count;

  @override
  Future<ReseedOutcome> run({
    void Function(ReseedProgress)? onProgress,
  }) async {
    final stack = await _stack;
    final preferencesClient = await stack
        .workspaceClientFactory(userPreferencesWorkspaceId(stack.userId));
    // One registry over the live store: reduced state is keyed by collection and
    // entity id, so both Workspaces read through the same views.
    final registry = CollectionRegistry(stack.database);
    final scratchStores = ReseedScratchStoreImpl();

    return runReseed(
      readLegacyRows: _readLegacyRows,
      gtdClient: stack.defaultClient,
      preferencesClient: preferencesClient,
      readReducedCollection: (collection) =>
          registry.register(collection).readAll(),
      powerSyncUploadQueueCount: _uploadQueueCount,
      mintTagId: initialUploadRandomTagId,
      onProgress: onProgress,
      buildScratchStack: (workspaceId) async {
        final live = await stack.workspaceClientFactory(workspaceId);
        final rootPk = await live.pinnedRootPk();
        if (rootPk == null) {
          throw StateError(
            'no Root is pinned for $workspaceId, so no scratch stack could '
            'verify a single control op — run the enrolment ceremony first',
          );
        }
        final escrowVersion = await live.highestEscrowVersionSeen();
        // Opened into locals so a failure between here and a built stack still has
        // a handle to close. `runReseed`'s `finally` only covers a stack that
        // exists; anything that throws during assembly would otherwise leave a
        // native connection open with nothing left holding it.
        final syncDatabase = scratchStores.openSyncDatabase();
        GtdDatabase? domain;
        try {
          domain = scratchStores.openDomainDatabase();
          return await assembleReseedScratchStack(
            workspaceId: workspaceId,
            userId: stack.userId,
            identity: stack.identity,
            clock: stack.clock,
            // The live stack's own wall clock and strategy registry, not a second
            // copy: the scratch reducer's skew guard and preference lattices have
            // to be the ones the device runs, or the verification would measure
            // this tool instead of the data.
            nowMs: stack.nowMs,
            strategies: stack.strategies,
            transport: live.transport,
            pinnedRootPk: rootPk,
            escrowVersion: escrowVersion,
            syncDatabase: syncDatabase,
            domain: domain,
          );
        } catch (_) {
          // Ownership never transferred, so closing here cannot double-close a
          // stack the caller went on to use.
          await domain?.close();
          await syncDatabase.close();
          rethrow;
        }
      },
    );
  }
}

final reseedRunnerProvider = Provider<ReseedRunner>(RiverpodReseedRunner.new);
