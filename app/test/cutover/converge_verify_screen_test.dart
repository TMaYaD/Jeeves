/// The converge-verify review surface over scripted outcomes.
///
/// Cutover tooling — removed by #556.
///
/// The screen's job is to make a verdict, its preconditions and the read-only
/// proof legible on the device, and to name the differing row ids. Those are what
/// is asserted here; the diff logic itself is `converge_differ_test.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/cutover/converge_verify/canonical_row.dart';
import 'package:jeeves/cutover/converge_verify/converge_differ.dart';
import 'package:jeeves/cutover/converge_verify/converge_verify_runner.dart';
import 'package:jeeves/cutover/converge_verify/converge_verify_screen.dart';
import 'package:jeeves/providers/sync_status_provider.dart';

class _StubRunner implements ConvergeVerifyRunner {
  _StubRunner(
    this._outcome, {
    this.comparisons = const [],
    this.comparisonError,
  });

  final ConvergeVerifyOutcome Function() _outcome;
  final List<RowComparison> comparisons;
  final Object? comparisonError;

  int runs = 0;
  String? lastSyncStateLabel;
  final List<String> comparedTables = [];

  @override
  Future<ConvergeVerifyOutcome> run({required String syncStateLabel}) async {
    runs++;
    lastSyncStateLabel = syncStateLabel;
    return _outcome();
  }

  @override
  Future<List<RowComparison>> compareRows(
      String table, List<String> ids) async {
    comparedTables.add(table);
    if (comparisonError case final error?) throw error;
    return comparisons;
  }
}

const _proofUnchanged = ReadOnlyProof(
  localDigestBefore: 'aaaaaaaaaaaaaaaa',
  localDigestAfter: 'aaaaaaaaaaaaaaaa',
  uploadQueueCountBefore: 0,
  uploadQueueCountAfter: 0,
);

const _preconditionsClean = ConvergePreconditions(
  uploadQueueCount: 0,
  deadLetterCount: 0,
  syncStateLabel: 'synced',
);

LocalConvergeReport _localReport({int todoCount = 1}) => LocalConvergeReport(
      tables: {
        for (final table in convergeVerifyTables)
          table: LocalTableReport(
            count: table == 'todos' ? todoCount : 0,
            nullIdRowCount: 0,
            rows: table == 'todos'
                ? {for (var i = 0; i < todoCount; i++) 'todo-$i': 'digest-$i'}
                : const {},
            anomalies: const [],
          ),
      },
    );

ServerConvergeReport _serverReport() => ServerConvergeReport(
      specVersion: convergeVerifySpecVersion,
      serverVersion: '0.9.1',
      generatedAt: '2026-07-29T10:00:00.000Z',
      excludedColumns: excludedColumnsReport(),
      tables: const {},
    );

TableDiff _diff(
  String table, {
  List<String> onlyLocal = const [],
  List<String> onlyServer = const [],
  List<String> mismatched = const [],
  int localCount = 0,
  int serverCount = 0,
}) =>
    TableDiff(
      table: table,
      localCount: localCount,
      serverCount: serverCount,
      localNullIdRowCount: 0,
      serverNullIdRowCount: 0,
      onlyLocalIds: onlyLocal,
      onlyServerIds: onlyServer,
      mismatchedIds: mismatched,
      localAnomalies: const [],
      serverAnomalies: const [],
    );

ConvergeVerifyOutcome _outcome({
  required ConvergeVerdict verdict,
  List<TableDiff> tables = const [],
  ServerConvergeReport? server,
  ReadOnlyProof proof = _proofUnchanged,
  ConvergePreconditions preconditions = _preconditionsClean,
}) =>
    ConvergeVerifyOutcome(
      verdict: verdict,
      local: _localReport(),
      server: server,
      tables: tables,
      readOnlyProof: proof,
      preconditions: preconditions,
    );

/// A `ListView` child below the fold is built but not hit-testable, so a plain
/// `tap` silently misses (docs/TESTING.md). Scroll it in first.
Future<void> _tapScrolled(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<_StubRunner> _pumpAndRun(
  WidgetTester tester,
  ConvergeVerifyOutcome outcome, {
  List<RowComparison> comparisons = const [],
  Object? comparisonError,
  SyncStatus syncStatus = SyncStatus.synced,
}) async {
  final runner = _StubRunner(
    () => outcome,
    comparisons: comparisons,
    comparisonError: comparisonError,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        convergeVerifyRunnerProvider.overrideWithValue(runner),
        // Stream.value, never a live watch: a pending Drift timer under
        // pumpAndSettle reads as an infinite hang (docs/TESTING.md).
        syncStatusProvider.overrideWith((ref) => Stream.value(syncStatus)),
      ],
      child: const MaterialApp(home: ConvergeVerifyScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('converge_run_button')));
  await tester.pumpAndSettle();
  return runner;
}

void main() {
  testWidgets('nothing runs until the user asks', (tester) async {
    final runner = _StubRunner(
      () => _outcome(verdict: ConvergeVerdict.converged),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          convergeVerifyRunnerProvider.overrideWithValue(runner),
          syncStatusProvider
              .overrideWith((ref) => Stream.value(SyncStatus.synced)),
        ],
        child: const MaterialApp(home: ConvergeVerifyScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(runner.runs, 0);
    expect(find.byKey(const Key('converge_verdict')), findsNothing);
    expect(find.text('Run check'), findsOneWidget);
  });

  testWidgets('a converged run renders the verdict and its evidence',
      (tester) async {
    final runner = await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.converged,
        server: _serverReport(),
        tables: [
          _diff('todos', localCount: 3, serverCount: 3),
          _diff('tags', localCount: 1, serverCount: 1),
        ],
      ),
    );

    expect(runner.runs, 1);
    expect(runner.lastSyncStateLabel, 'synced');
    expect(
      tester.widget<Text>(find.byKey(const Key('converge_verdict'))).data,
      contains('Converged'),
    );
    // The three claims the plan review made binding must be on screen, not just
    // in a test: the read-only proof, the preconditions, and what is excluded.
    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_read_only_proof')))
          .data,
      contains('unchanged'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_preconditions')))
          .data,
      contains('upload queue 0'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('converge_exclusions'))).data,
      contains('time_spent_minutes'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_server_version')))
          .data,
      contains('0.9.1'),
    );
    expect(find.byKey(const Key('converge_status_todos_converged')),
        findsOneWidget);
    expect(find.byKey(const Key('converge_copy_json')), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);
  });

  testWidgets('a diverged run names the differing row ids per table',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.diverged,
        server: _serverReport(),
        tables: [
          _diff('todos',
              localCount: 2,
              serverCount: 1,
              onlyLocal: ['todo-local-only'],
              mismatched: ['todo-different']),
          _diff('tags',
              localCount: 0, serverCount: 1, onlyServer: ['tag-server-only']),
        ],
      ),
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('converge_verdict'))).data,
      contains('Diverged'),
    );
    expect(find.byKey(const Key('converge_status_todos_diverged')),
        findsOneWidget);

    await _tapScrolled(tester, const Key('converge_table_todos'));
    expect(
      find.byKey(const Key('converge_only_local_todos_todo-local-only')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('converge_mismatched_todos_todo-different')),
      findsOneWidget,
    );
  });

  testWidgets('a mismatch can be read column by column', (tester) async {
    final localCanonical = canonicalRow('tags', const {
      'color': null,
      'id': 'tag-1',
      'name': '@work',
      'type': 'context',
    }).canonical;
    final serverCanonical = canonicalRow('tags', const {
      'color': null,
      'id': 'tag-1',
      'name': '@home',
      'type': 'context',
    }).canonical;

    final runner = await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.diverged,
        server: _serverReport(),
        tables: [
          _diff('tags', localCount: 1, serverCount: 1, mismatched: ['tag-1']),
        ],
      ),
      comparisons: [
        RowComparison(
          id: 'tag-1',
          localCanonical: localCanonical,
          serverCanonical: serverCanonical,
        ),
      ],
    );

    await _tapScrolled(tester, const Key('converge_table_tags'));
    await _tapScrolled(tester, const Key('converge_compare_tags'));

    expect(runner.comparedTables, ['tags']);
    // Only the column that actually differs is named — that is what tells a real
    // divergence from a bug in the normaliser.
    expect(
      find.byKey(const Key('converge_column_tags_tag-1_name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('converge_column_tags_tag-1_type')),
      findsNothing,
    );
  });

  testWidgets('an older server renders a skew state, not a failure',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(verdict: ConvergeVerdict.serverNotDeployed),
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('converge_verdict'))).data,
      contains('Server not yet deployed'),
    );
    expect(find.byKey(const Key('converge_error')), findsNothing);
    // The local half still computed, so the screen is not blank.
    expect(find.byKey(const Key('converge_local_only_todos')), findsOneWidget);
  });

  testWidgets('a failed read-only proof outranks the data verdict',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.readOnlyProofFailed,
        server: _serverReport(),
        proof: const ReadOnlyProof(
          localDigestBefore: 'aaaaaaaaaaaa',
          localDigestAfter: 'bbbbbbbbbbbb',
          uploadQueueCountBefore: 0,
          uploadQueueCountAfter: 1,
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('converge_verdict'))).data,
      contains('Read-only proof failed'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_read_only_proof')))
          .data,
      contains('CHANGED'),
    );
  });

  testWidgets('pending uploads are surfaced as an unmet premise',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.notFullySynced,
        server: _serverReport(),
        preconditions: const ConvergePreconditions(
          uploadQueueCount: 2,
          deadLetterCount: 1,
          syncStateLabel: 'error',
        ),
      ),
      syncStatus: SyncStatus.error,
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('converge_verdict'))).data,
      contains('Not fully synced'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_preconditions')))
          .data,
      allOf(contains('upload queue 2'), contains('dead letters 1')),
    );
  });

  testWidgets('a thrown error is reported rather than swallowed',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          convergeVerifyRunnerProvider
              .overrideWithValue(_ThrowingRunner('network down')),
          syncStatusProvider
              .overrideWith((ref) => Stream.value(SyncStatus.synced)),
        ],
        child: const MaterialApp(home: ConvergeVerifyScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('converge_run_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('converge_error'))).data,
      contains('network down'),
    );
    expect(find.byKey(const Key('converge_verdict')), findsNothing);
  });

  testWidgets('a failed re-run does not leave the earlier verdict on screen',
      (tester) async {
    var runs = 0;
    final runner = _StubRunner(() {
      runs++;
      if (runs > 1) throw StateError('store went away');
      return _outcome(
        verdict: ConvergeVerdict.converged,
        server: _serverReport(),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          convergeVerifyRunnerProvider.overrideWithValue(runner),
          syncStatusProvider
              .overrideWith((ref) => Stream.value(SyncStatus.synced)),
        ],
        child: const MaterialApp(home: ConvergeVerifyScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('converge_run_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('converge_verdict')), findsOneWidget);

    await tester.tap(find.byKey(const Key('converge_run_button')));
    await tester.pumpAndSettle();

    // A stale "Converged" next to the error is the confusion this tool exists to
    // avoid: nothing about the previous run survives a failed one.
    expect(find.byKey(const Key('converge_verdict')), findsNothing);
    expect(find.byKey(const Key('converge_read_only_proof')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('converge_error'))).data,
      contains('store went away'),
    );
  });

  testWidgets('a re-subscribed sync status is recorded, not read as unknown',
      (tester) async {
    // `syncStatusProvider` watches `currentUserIdProvider`, so its stream is
    // rebuilt whenever that changes. Riverpod then holds `AsyncLoading` carrying
    // the last real status until the new stream emits — the state `asData` cannot
    // see. Recording that as "unknown" would misreport the run's premise.
    // A fresh identity per build, so invalidating it really does notify.
    final dependency = Provider<Object>((ref) => Object());
    final status = StreamController<SyncStatus>.broadcast();
    addTearDown(status.close);
    final runner = _StubRunner(
      () => _outcome(verdict: ConvergeVerdict.converged),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          convergeVerifyRunnerProvider.overrideWithValue(runner),
          syncStatusProvider.overrideWith((ref) {
            ref.watch(dependency);
            return status.stream;
          }),
        ],
        child: const MaterialApp(home: ConvergeVerifyScreen()),
      ),
    );
    status.add(SyncStatus.synced);
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('converge_run_button'))),
    );
    container.invalidate(dependency);
    await tester.pumpAndSettle();
    expect(container.read(syncStatusProvider).asData, isNull,
        reason: 'the rebuilt provider must be in the retained-value state');

    await tester.tap(find.byKey(const Key('converge_run_button')));
    await tester.pumpAndSettle();

    expect(runner.lastSyncStateLabel, 'synced');
  });

  testWidgets('a failed column comparison is reported, not a silent no-op',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.diverged,
        server: _serverReport(),
        tables: [
          _diff('tags', localCount: 1, serverCount: 1, mismatched: ['tag-1']),
        ],
      ),
      comparisonError: StateError('local store unreadable'),
    );

    await _tapScrolled(tester, const Key('converge_table_tags'));
    await _tapScrolled(tester, const Key('converge_compare_tags'));

    expect(
      tester
          .widget<Text>(find.byKey(const Key('converge_comparison_error_tags')))
          .data,
      contains('local store unreadable'),
    );
  });

  testWidgets('an unavailable server detail is not blamed on the normaliser',
      (tester) async {
    await _pumpAndRun(
      tester,
      _outcome(
        verdict: ConvergeVerdict.diverged,
        server: _serverReport(),
        tables: [
          _diff('tags', localCount: 1, serverCount: 1, mismatched: ['tag-1']),
        ],
      ),
      comparisons: [
        RowComparison(
          id: 'tag-1',
          localCanonical: canonicalRow('tags', const {
            'color': null,
            'id': 'tag-1',
            'name': '@work',
            'type': 'context',
          }).canonical,
          serverCanonical: null,
          serverDetailUnavailable: true,
        ),
      ],
    );

    await _tapScrolled(tester, const Key('converge_table_tags'));
    await _tapScrolled(tester, const Key('converge_compare_tags'));

    // "The mismatch is in this tool" is a positive claim about the data, and a
    // detail request that never answered cannot support it.
    expect(
      tester
          .widget<Text>(
              find.byKey(const Key('converge_comparison_note_tags_tag-1')))
          .data,
      allOf(
        contains('Server row detail unavailable'),
        isNot(contains('in this tool')),
      ),
    );
  });
}

class _ThrowingRunner implements ConvergeVerifyRunner {
  _ThrowingRunner(this.message);

  final String message;

  @override
  Future<ConvergeVerifyOutcome> run({required String syncStateLabel}) async =>
      throw StateError(message);

  @override
  Future<List<RowComparison>> compareRows(
          String table, List<String> ids) async =>
      const [];
}
