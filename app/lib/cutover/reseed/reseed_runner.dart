/// One reseed run, and the wiring that gives it a real device.
///
/// **Cutover tooling — removed by #556.**
///
/// [runReseed] is the whole ceremony with every dependency injected, so the run
/// under test is the run that happens on the phone: production hands in
/// PowerSync's `getAll`, the enrolled clients off `syncStackProvider` and native
/// scratch stores; a test hands in a seeded legacy database, a `SimDevice`'s
/// clients and in-memory ones. There is no second code path.
///
/// The stage order is load-bearing in one place: **pull before authoring**. The
/// diff skip that makes a re-run safe compares against the new spine's reduced
/// state, so a device whose sync store was rebuilt has to have the log back
/// before it decides what is missing — otherwise it re-authors the entire store.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../../providers/powersync_provider.dart';
import '../../providers/sync_stack_provider.dart';
import '../../sync/collection_codecs.dart';
import '../../sync/ids.dart';
import '../../sync/reducer.dart';
import '../../sync/sync_client.dart';
import '../../sync/sync_stack.dart';
import '../converge_verify/converge_differ.dart'
    show ReadOnlyProof, buildLocalConvergeReport;
import 'reseed_plan.dart';
import 'reseed_report.dart';
import 'reseed_scratch_store.dart';
import 'reseed_uploader.dart';
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
  final ReseedUploadProgress? upload;

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
  required ReseedRowSource readLegacyRows,
  required SyncClient gtdClient,
  required SyncClient preferencesClient,
  required ReducedCollectionReader readReducedCollection,
  required ReseedScratchStackFactory buildScratchStack,
  required Future<int?> Function() powerSyncUploadQueueCount,
  required String Function() mintTagId,
  void Function(ReseedProgress)? onProgress,
  int flushEveryOpCount = reseedFlushEveryOpCount,
}) async {
  void report(ReseedStage stage, [ReseedUploadProgress? upload]) =>
      onProgress?.call(ReseedProgress(stage: stage, upload: upload));

  report(ReseedStage.checkingPreconditions);
  // Both snapshots bracket everything the run does, so the proof covers the
  // authoring and the verification too, not just the planning read.
  final queueBefore = await powerSyncUploadQueueCount();
  final legacyDigestBefore =
      (await buildLocalConvergeReport(readLegacyRows)).digest;

  final enrolled = gtdClient.isEnrolled && preferencesClient.isEnrolled;
  final rootPinned = await gtdClient.pinnedRootPk() != null;

  var pulledBeforeAuthoring = false;
  if (enrolled && rootPinned) {
    report(ReseedStage.pulling);
    await gtdClient.sync();
    await preferencesClient.sync();
    pulledBeforeAuthoring = true;
  }

  report(ReseedStage.planning);
  final plan = await buildReseedPlan(
    readLegacyRows: readLegacyRows,
    userId: gtdClient.userId,
    preferencesWorkspaceId: preferencesClient.workspaceId,
    mintTagId: mintTagId,
    spineLabelTagsByName: pulledBeforeAuthoring
        ? await readSpineLabelTags(readReducedCollection)
        : const {},
  );

  ReseedUploadReport? upload;
  final tables = <ReseedTableDiff>[];
  var pendingOpCount = 0;

  if (pulledBeforeAuthoring) {
    report(ReseedStage.authoring);
    upload = await runReseedUpload(
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
    for (final workspace in ReseedWorkspace.values) {
      final live = workspace == ReseedWorkspace.preferences
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
  tables.sort((a, b) => reseedCollectionOrder
      .indexOf(a.table)
      .compareTo(reseedCollectionOrder.indexOf(b.table)));

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

/// The new spine's Labels, keyed by casefolded name.
///
/// What makes a re-run stable: run 1 minted a Label for a converted Area, run 2
/// finds it here and merges onto it rather than minting a second one. Same-name
/// Labels resolve by `(casefolded name, id)` — the one total order the plan uses
/// everywhere — so two Labels called "Home" cannot make the pick depend on read
/// order.
Future<Map<String, ReseedTagRef>> readSpineLabelTags(
  ReducedCollectionReader readReducedCollection,
) async {
  final reduced = await readReducedCollection(tagsCollection);
  final labels = <ReseedTagRef>[];
  for (final entry in reduced.entries) {
    if (entry.value['type'] != labelTagType) continue;
    final name = entry.value['name'];
    if (name is! String) continue;
    labels.add(ReseedTagRef(id: entry.key, name: name));
  }
  labels.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  final byName = <String, ReseedTagRef>{};
  for (final label in labels) {
    byName.putIfAbsent(label.name.toLowerCase(), () => label);
  }
  return byName;
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
    final rows = await (await _powerSync).getAll('SELECT * FROM $table');
    return [for (final row in rows) Map<String, Object?>.of(row)];
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
      mintTagId: reseedRandomTagId,
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
        return assembleReseedScratchStack(
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
          escrowVersion: await live.highestEscrowVersionSeen(),
          syncDatabase: scratchStores.openSyncDatabase(),
          domain: scratchStores.openDomainDatabase(),
        );
      },
    );
  }
}

final reseedRunnerProvider = Provider<ReseedRunner>(RiverpodReseedRunner.new);
