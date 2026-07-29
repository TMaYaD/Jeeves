/// The converge-verify review surface (#553 Phase 1, issue #582).
///
/// **Cutover tooling — removed by #556**, together with the settings entry and
/// the route that reach it.
///
/// The user runs this on the phone that holds the only copy of their store and
/// reads the verdict there, which is what makes "reviewable by the user" true
/// without an adb-attached debug build (the production build is release-signed,
/// so `run-as` cannot reach its database — docs/TESTING.md).
///
/// Deliberately plain: it is a diagnostic table, not a designed product surface,
/// and it will be deleted rather than maintained.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/sync_status_provider.dart';
import 'canonical_row.dart';
import 'converge_differ.dart';
import 'converge_verify_runner.dart';

class ConvergeVerifyScreen extends ConsumerStatefulWidget {
  const ConvergeVerifyScreen({super.key});

  static const String routePath = '/settings/converge-verify';

  @override
  ConsumerState<ConvergeVerifyScreen> createState() =>
      _ConvergeVerifyScreenState();
}

class _ConvergeVerifyScreenState extends ConsumerState<ConvergeVerifyScreen> {
  bool _running = false;
  ConvergeVerifyOutcome? _outcome;
  Object? _error;

  /// Loaded on demand, per table: the column-level reading of its mismatches.
  final Map<String, List<RowComparison>> _comparisons = {};

  Future<void> _run(String syncStateLabel) async {
    setState(() {
      _running = true;
      _error = null;
      _comparisons.clear();
    });
    try {
      final outcome = await ref
          .read(convergeVerifyRunnerProvider)
          .run(syncStateLabel: syncStateLabel);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _running = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _running = false;
      });
    }
  }

  /// Read off the *watched* provider, never `ref.read` on an unwatched one: an
  /// unsubscribed StreamProvider is still `AsyncLoading` when a button callback
  /// reads it, which would quietly record every run's sync state as "unknown".
  String _syncStateLabel(AsyncValue<SyncStatus> status) {
    if (status.hasError) return 'error';
    return status.asData?.value.name ?? 'unknown';
  }

  Future<void> _loadComparisons(TableDiff table) async {
    final comparisons = await ref
        .read(convergeVerifyRunnerProvider)
        .compareRows(table.table, table.mismatchedIds);
    if (!mounted) return;
    setState(() => _comparisons[table.table] = comparisons);
  }

  Future<void> _copyJson(ConvergeVerifyOutcome outcome) async {
    final json = const JsonEncoder.withIndent('  ').convert(outcome.toJson());
    await Clipboard.setData(ClipboardData(text: json));
    // Also to the log, so `adb logcat` keeps an archival copy that can be pasted
    // into the issue even if the clipboard is lost.
    debugPrint('converge-verify report: $json');
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final syncStateLabel = _syncStateLabel(ref.watch(syncStatusProvider));
    return Scaffold(
      appBar: AppBar(title: const Text('Converge-verify')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Compares this device\'s store with the server mirror, table by '
            'table. Read-only on both sides. Cutover tooling — removed once the '
            'sync pivot lands.',
            key: Key('converge_blurb'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('converge_run_button'),
            onPressed: _running ? null : () => _run(syncStateLabel),
            child: Text(outcome == null ? 'Run check' : 'Run again'),
          ),
          if (_running)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(
                  key: Key('converge_running'),
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'The check could not run: $_error',
                key: const Key('converge_error'),
              ),
            ),
          if (outcome != null) ..._results(outcome),
        ],
      ),
    );
  }

  List<Widget> _results(ConvergeVerifyOutcome outcome) => [
        const SizedBox(height: 16),
        Text(
          _verdictHeadline(outcome),
          key: const Key('converge_verdict'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _verdictExplanation(outcome),
          key: const Key('converge_verdict_explanation'),
        ),
        const SizedBox(height: 12),
        Text(
          'Preconditions: upload queue '
          '${outcome.preconditions.uploadQueueCount ?? 'n/a'}, dead letters '
          '${outcome.preconditions.deadLetterCount}, sync state '
          '${outcome.preconditions.syncStateLabel}',
          key: const Key('converge_preconditions'),
        ),
        const SizedBox(height: 4),
        Text(
          outcome.readOnlyProof.summaryLine,
          key: const Key('converge_read_only_proof'),
        ),
        const SizedBox(height: 4),
        Text(
          'Not compared: ${_excludedSummary()}',
          key: const Key('converge_exclusions'),
        ),
        if (outcome.server case final server?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Server ${server.serverVersion}, report ${server.generatedAt}',
              key: const Key('converge_server_version'),
            ),
          ),
        const SizedBox(height: 12),
        TextButton(
          key: const Key('converge_copy_json'),
          onPressed: () => _copyJson(outcome),
          child: const Text('Copy JSON (also written to logcat)'),
        ),
        const Divider(),
        for (final table in outcome.tables) _tableTile(table),
        if (outcome.tables.isEmpty)
          for (final entry in outcome.local.tables.entries)
            ListTile(
              key: Key('converge_local_only_${entry.key}'),
              dense: true,
              title: Text(entry.key),
              subtitle: Text('local ${entry.value.count} rows'),
            ),
      ];

  String _excludedSummary() => excludedColumnsReport()
      .entries
      .map((entry) => '${entry.key}: ${entry.value.join(', ')}')
      .join('; ');

  String _verdictHeadline(ConvergeVerifyOutcome outcome) =>
      switch (outcome.verdict) {
        ConvergeVerdict.converged => 'Converged — every table matches',
        ConvergeVerdict.diverged =>
          'Diverged — ${outcome.divergedTables.length} table(s) differ',
        ConvergeVerdict.notFullySynced => 'Not fully synced yet',
        ConvergeVerdict.serverNotDeployed => 'Server not yet deployed',
        ConvergeVerdict.specVersionMismatch => 'Server speaks a different spec',
        ConvergeVerdict.readOnlyProofFailed => 'Read-only proof failed',
      };

  String _verdictExplanation(ConvergeVerifyOutcome outcome) =>
      switch (outcome.verdict) {
        ConvergeVerdict.converged =>
          'Every row id and every row digest agrees on both sides, with no '
              'anomalies and nothing pending.',
        ConvergeVerdict.diverged =>
          'Open a table below for the row ids, then compare columns to tell a '
              'real difference from a normaliser bug.',
        ConvergeVerdict.notFullySynced =>
          'This device is still holding writes the server has not seen, so '
              'matching digests would be luck and differing ones are expected. '
              'Let sync settle, clear any dead letters, and run again.',
        ConvergeVerdict.serverNotDeployed =>
          'This build of the app is newer than the running server: the '
              'converge-verify endpoint is not there yet. Wait for the backend '
              'deploy and run again.',
        ConvergeVerdict.specVersionMismatch =>
          'The server computes digests to a different spec version, so the two '
              'reports are not comparable. Refusing rather than guessing.',
        ConvergeVerdict.readOnlyProofFailed =>
          'The store or the upload queue changed during the run, so this tool '
              'cannot vouch for its own answer. Nothing about the data is being '
              'claimed.',
      };

  Widget _tableTile(TableDiff table) {
    final comparisons = _comparisons[table.table];
    return ExpansionTile(
      key: Key('converge_table_${table.table}'),
      title: Text(table.table),
      subtitle: Text(
        'local ${table.localCount} / server ${table.serverCount}'
        '${table.converged ? ' — converged' : ' — ${table.differenceCount} difference(s)'}'
        '${table.serverNullIdRowCount > 0 ? ', ${table.serverNullIdRowCount} server row(s) with no id' : ''}'
        '${table.localNullIdRowCount > 0 ? ', ${table.localNullIdRowCount} local row(s) with no id' : ''}',
      ),
      trailing: Icon(
        table.converged ? Icons.check : Icons.priority_high,
        key: Key(
          'converge_status_${table.table}_'
          '${table.converged ? 'converged' : 'diverged'}',
        ),
      ),
      children: [
        _idBlock('Only on this device', table.onlyLocalIds,
            'converge_only_local_${table.table}'),
        _idBlock('Only on the server', table.onlyServerIds,
            'converge_only_server_${table.table}'),
        _idBlock('Different content', table.mismatchedIds,
            'converge_mismatched_${table.table}'),
        for (final anomaly in table.localAnomalies)
          ListTile(
            dense: true,
            title: Text('local anomaly: ${anomaly.column} — ${anomaly.kind}'),
            subtitle: Text('row ${anomaly.rowId ?? '(no id)'}: ${anomaly.raw}'),
          ),
        for (final anomaly in table.serverAnomalies)
          ListTile(
            dense: true,
            title: Text('server anomaly: ${anomaly.column} — ${anomaly.kind}'),
            subtitle: Text('row ${anomaly.rowId ?? '(no id)'}: ${anomaly.raw}'),
          ),
        if (table.mismatchedIds.isNotEmpty)
          TextButton(
            key: Key('converge_compare_${table.table}'),
            onPressed: () => _loadComparisons(table),
            child: const Text('Compare columns'),
          ),
        if (comparisons != null)
          for (final comparison in comparisons)
            _comparisonBlock(table.table, comparison),
      ],
    );
  }

  Widget _idBlock(String label, List<String> ids, String keyPrefix) {
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label (${ids.length})',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final id in ids)
            Text(id, key: Key('${keyPrefix}_$id')),
        ],
      ),
    );
  }

  Widget _comparisonBlock(String table, RowComparison comparison) {
    final differences = comparison.differencesFor(table);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(comparison.id,
              key: Key('converge_comparison_${table}_${comparison.id}'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (differences.isEmpty)
            const Text(
              'No column difference visible — the two sides encode the same '
              'values, so the mismatch is in this tool, not the data.',
            ),
          for (final difference in differences)
            Text(
              '${difference.column}: local ${difference.local} / '
              'server ${difference.server}',
              key: Key(
                'converge_column_${table}_${comparison.id}_${difference.column}',
              ),
            ),
        ],
      ),
    );
  }
}
