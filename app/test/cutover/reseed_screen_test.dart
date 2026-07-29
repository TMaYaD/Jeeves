/// The reseed surface over scripted outcomes.
///
/// **Cutover tooling — removed by #556.**
///
/// The screen's job is to make the verdict, the preconditions, the read-only
/// proof, the op counters and the ADR-0025 worklist legible on the device, and to
/// name the differing entity ids. Those are what is asserted here; the transform
/// and the comparison have their own suites.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/cutover/converge_verify/converge_differ.dart'
    show ReadOnlyProof;
import 'package:jeeves/cutover/reseed/reseed_plan.dart';
import 'package:jeeves/cutover/reseed/reseed_report.dart';
import 'package:jeeves/cutover/reseed/reseed_runner.dart';
import 'package:jeeves/cutover/reseed/reseed_screen.dart';
import 'package:jeeves/cutover/reseed/reseed_uploader.dart';
import 'package:jeeves/cutover/reseed/reseed_verifier.dart';
import 'package:jeeves/sync/collection_codecs.dart';

class _StubRunner implements ReseedRunner {
  _StubRunner(this._outcome, {this.stages = const []});

  final ReseedOutcome Function() _outcome;

  /// Progress the runner emits before it answers, so the screen's stage line can
  /// be asserted while a run is in flight.
  final List<ReseedProgress> stages;

  int runs = 0;
  final Completer<void> released = Completer<void>();
  bool gate = false;

  @override
  Future<ReseedOutcome> run({
    void Function(ReseedProgress)? onProgress,
  }) async {
    runs++;
    for (final stage in stages) {
      onProgress?.call(stage);
    }
    if (gate) await released.future;
    return _outcome();
  }
}

const _proofUnchanged = ReadOnlyProof(
  localDigestBefore: 'aaaaaaaaaaaaaaaa',
  localDigestAfter: 'aaaaaaaaaaaaaaaa',
  uploadQueueCountBefore: 0,
  uploadQueueCountAfter: 0,
);

const _proofChanged = ReadOnlyProof(
  localDigestBefore: 'aaaaaaaaaaaaaaaa',
  localDigestAfter: 'bbbbbbbbbbbbbbbb',
  uploadQueueCountBefore: 0,
  uploadQueueCountAfter: 1,
);

const _preconditionsClean = ReseedPreconditions(
  enrolled: true,
  rootPinned: true,
  pulledBeforeAuthoring: true,
  pendingOpCountAfterFlush: 0,
);

ReseedPlan _plan({
  List<AreaExclusivityResolution> resolutions = const [],
  Map<String, List<String>> excluded = const {},
}) =>
    ReseedPlan(
      entities: const [],
      resolutions: resolutions,
      anomalies: const [],
      legacyRowCountByTable: const {'todos': 3},
      excludedRowIdsByTable: excluded,
      endorsedEntityIdsByCollection: const {},
    );

const _upload = ReseedUploadReport(
  plannedEntityCount: 12,
  authoredOpCount: 10,
  skippedEntityCount: 2,
  reassertedEntityCount: 1,
  refusedEntityCount: 0,
  anomalies: [],
);

ReseedTableDiff _table({
  String table = todosCollection,
  List<String> onlyInLegacy = const [],
  List<String> heldBack = const [],
}) =>
    ReseedTableDiff(
      table: table,
      plannedCount: 3,
      reducedCount: 3 - onlyInLegacy.length,
      projectedRowCount: 3 - onlyInLegacy.length - heldBack.length,
      onlyInLegacyIds: onlyInLegacy,
      onlyInReducedIds: const [],
      mismatchedIds: const [],
      heldBackIds: heldBack,
      legacyAnomalies: const [],
      reducedAnomalies: const [],
    );

ReseedOutcome _outcome({
  ReseedVerdict verdict = ReseedVerdict.reseededAndConverged,
  ReseedPlan? plan,
  ReseedUploadReport? upload = _upload,
  List<ReseedTableDiff> tables = const [],
  ReadOnlyProof proof = _proofUnchanged,
  ReseedPreconditions preconditions = _preconditionsClean,
}) =>
    ReseedOutcome(
      verdict: verdict,
      plan: plan ?? _plan(),
      upload: upload,
      tables: tables.isEmpty ? [_table()] : tables,
      readOnlyProof: proof,
      preconditions: preconditions,
    );

Future<void> _pump(WidgetTester tester, _StubRunner runner) async {
  // A tall surface: a `ListView` only inflates children near the visible window,
  // so on the default 800px one the table tiles would be absent from the tree and
  // a finder that missed them would read as "the screen shows no tables".
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [reseedRunnerProvider.overrideWithValue(runner)],
      child: const MaterialApp(home: ReseedScreen()),
    ),
  );
}

void main() {
  testWidgets('offers a run and says the run is repeatable', (tester) async {
    final runner = _StubRunner(_outcome);
    await _pump(tester, runner);

    expect(find.byKey(const Key('reseed_blurb')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_blurb'))).data,
      contains('Safe to run again'),
    );
    expect(find.text('Run reseed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    expect(runner.runs, 1);
    // Re-tapping is the documented way to finish an interrupted run, so the
    // button stays live and says so.
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('shows the stage line while the run is in flight',
      (tester) async {
    final runner = _StubRunner(
      _outcome,
      stages: const [ReseedProgress(stage: ReseedStage.verifying)],
    )..gate = true;
    await _pump(tester, runner);

    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pump();

    expect(find.byKey(const Key('reseed_running')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_progress'))).data,
      contains('Reducing the server log from zero'),
    );

    runner.released.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reseed_running')), findsNothing);
  });

  testWidgets('renders the verdict, the counters and the proof',
      (tester) async {
    await _pump(tester, _StubRunner(_outcome));
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_verdict'))).data,
      contains('Reseeded'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_counters'))).data,
      allOf(contains('10 authored'), contains('2 already present'),
          contains('1 re-asserted')),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_read_only_proof'))).data,
      contains('unchanged'),
    );
    expect(
      find.byKey(const Key('reseed_status_${todosCollection}_converged')),
      findsOneWidget,
    );
  });

  testWidgets('names the entity ids a diverged table disagrees on',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(() => _outcome(
            verdict: ReseedVerdict.diverged,
            tables: [
              _table(onlyInLegacy: const ['entity-a'], heldBack: const ['entity-b']),
            ],
          )),
    );
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_verdict'))).data,
      contains('Diverged'),
    );
    await tester.tap(find.byKey(const Key('reseed_table_$todosCollection')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('reseed_only_legacy_${todosCollection}_entity-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('reseed_held_back_${todosCollection}_entity-b')),
      findsOneWidget,
    );
  });

  testWidgets('lists the ADR-0025 conversions as the Weekly Review worklist',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(() => _outcome(
            plan: _plan(resolutions: [
              AreaExclusivityResolution(
                outcomeId: 'outcome-1',
                outcomeTitle: 'Three Areas at once',
                keptArea: const ReseedTagRef(id: 'area-1', name: 'admin'),
                converted: const [
                  AreaMembershipConversion(
                    area: ReseedTagRef(id: 'area-2', name: 'Home'),
                    label: ReseedTagRef(id: 'label-1', name: 'Home'),
                    labelOrigin: labelOriginLegacyTag,
                    collapsedOntoExistingMembership: false,
                  ),
                ],
              ),
            ]),
          )),
    );
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('reseed_area_exclusivity')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reseed_resolution_outcome-1')), findsOneWidget);
    expect(find.text('kept Area: admin'), findsOneWidget);
    expect(
      find.text('Area "Home" → Label "Home" (legacy)'),
      findsOneWidget,
    );
  });

  testWidgets('says a partially reseeded store is not fully carried',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(() => _outcome(
            verdict: ReseedVerdict.partiallyReseeded,
            plan: _plan(excluded: const {'todos': ['untitled-row']}),
          )),
    );
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_verdict'))).data,
      contains('1 row(s) left behind'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_excluded_rows'))).data,
      contains('1 legacy row(s)'),
    );
  });

  testWidgets('claims nothing about the data when the proof fails',
      (tester) async {
    await _pump(
      tester,
      _StubRunner(() => _outcome(
            verdict: ReseedVerdict.readOnlyProofFailed,
            proof: _proofChanged,
          )),
    );
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_verdict'))).data,
      contains('Read-only proof failed'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('reseed_verdict_explanation')))
          .data,
      contains('Nothing about the data is being claimed'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_read_only_proof'))).data,
      contains('CHANGED'),
    );
  });

  testWidgets('a failed run leaves no stale verdict beside the error',
      (tester) async {
    var shouldThrow = false;
    final runner = _StubRunner(() {
      if (shouldThrow) throw StateError('no Root is pinned');
      return _outcome();
    });
    await _pump(tester, runner);

    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reseed_verdict')), findsOneWidget);

    shouldThrow = true;
    await tester.tap(find.byKey(const Key('reseed_run_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reseed_verdict')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('reseed_error'))).data,
      contains('no Root is pinned'),
    );
  });
}
