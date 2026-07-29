/// The reseed surface (#553 Phase 2, issue #587).
///
/// **Cutover tooling — removed by #556**, together with the settings entry and
/// the route that reach it.
///
/// The user runs this on the phone that holds the only copy of their store and
/// reads the verdict there — the same reason converge-verify is a screen rather
/// than an adb script: the production build is release-signed, so `run-as` cannot
/// reach its database.
///
/// Deliberately plain: a diagnostic surface, not a designed product one, and it
/// will be deleted rather than maintained. **Re-tapping Run is safe** — the run is
/// idempotent by construction (see `reseed_uploader.dart`), which is why the
/// button says so rather than being disabled after a pass.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'reseed_plan.dart';
import 'reseed_report.dart';
import 'reseed_runner.dart';
import 'reseed_verifier.dart';

class ReseedScreen extends ConsumerStatefulWidget {
  const ReseedScreen({super.key});

  static const String routePath = '/settings/reseed';

  @override
  ConsumerState<ReseedScreen> createState() => _ReseedScreenState();
}

class _ReseedScreenState extends ConsumerState<ReseedScreen> {
  bool _running = false;
  ReseedProgress? _progress;
  ReseedOutcome? _outcome;
  Object? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      // The previous verdict, proof and counters describe the previous run. A run
      // that fails must not leave them on screen next to the error.
      _outcome = null;
      _progress = null;
    });
    try {
      final outcome = await ref.read(reseedRunnerProvider).run(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
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

  Future<void> _copyJson(ReseedOutcome outcome) async {
    final json = const JsonEncoder.withIndent('  ').convert(outcome.toJson());
    await Clipboard.setData(ClipboardData(text: json));
    // The verdict only. Unlike converge-verify's report — ids and digests — this
    // one carries legacy content (Outcome titles, Tag names) through
    // `plan.toJson()`, and `debugPrint` writes in release builds too, so the full
    // report would land in `adb logcat` and in any bug report taken afterwards.
    // The clipboard is the archival copy; a lost one is a re-run away, because the
    // reseed is idempotent.
    debugPrint('reseed report copied: verdict=${outcome.verdict.name}');
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    return Scaffold(
      appBar: AppBar(title: const Text('Reseed')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Authors this device\'s legacy store onto the op-log spine as signed '
            'ops, then reduces the server log from zero and compares it with the '
            'source. Read-only on the legacy side. Safe to run again — it skips '
            'whatever the spine already holds. Cutover tooling — removed once the '
            'sync pivot lands.',
            key: Key('reseed_blurb'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('reseed_run_button'),
            onPressed: _running ? null : _run,
            child: Text(outcome == null ? 'Run reseed' : 'Run again'),
          ),
          if (_running)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  const CircularProgressIndicator(key: Key('reseed_running')),
                  const SizedBox(height: 12),
                  Text(
                    _progress?.summaryLine ?? 'Starting…',
                    key: const Key('reseed_progress'),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'The reseed could not run: $_error',
                key: const Key('reseed_error'),
              ),
            ),
          if (outcome != null) ..._results(outcome),
        ],
      ),
    );
  }

  List<Widget> _results(ReseedOutcome outcome) => [
        const SizedBox(height: 16),
        Text(
          _verdictHeadline(outcome),
          key: const Key('reseed_verdict'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _verdictExplanation(outcome),
          key: const Key('reseed_verdict_explanation'),
        ),
        const SizedBox(height: 12),
        Text(
          'Preconditions: '
          '${outcome.preconditions.enrolled ? 'enrolled' : 'NOT enrolled'}, '
          '${outcome.preconditions.rootPinned ? 'Root pinned' : 'no Root pinned'}, '
          '${outcome.preconditions.pulledBeforeAuthoring ? 'pulled first' : 'did not pull'}, '
          '${outcome.preconditions.pendingOpCountAfterFlush} op(s) still queued',
          key: const Key('reseed_preconditions'),
        ),
        const SizedBox(height: 4),
        Text(
          outcome.readOnlyProof.summaryLine,
          key: const Key('reseed_read_only_proof'),
        ),
        const SizedBox(height: 4),
        if (outcome.upload case final upload?)
          Text(
            'Ops: ${upload.authoredOpCount} authored, '
            '${upload.skippedEntityCount} already present, '
            '${upload.reassertedEntityCount} re-asserted, '
            '${upload.refusedEntityCount} refused '
            '(of ${upload.plannedEntityCount} planned)',
            key: const Key('reseed_counters'),
          ),
        const SizedBox(height: 4),
        Text(
          'Not carried: ${outcome.plan.excludedRowCount} legacy row(s)',
          key: const Key('reseed_excluded_rows'),
        ),
        const SizedBox(height: 12),
        TextButton(
          key: const Key('reseed_copy_json'),
          onPressed: () => _copyJson(outcome),
          child: const Text('Copy JSON (also written to logcat)'),
        ),
        const Divider(),
        _areaExclusivityTile(outcome.plan),
        const Divider(),
        for (final table in outcome.tables) _tableTile(table),
      ];

  String _verdictHeadline(ReseedOutcome outcome) => switch (outcome.verdict) {
        ReseedVerdict.reseededAndConverged =>
          'Reseeded — the spine reduces to the same store',
        ReseedVerdict.partiallyReseeded =>
          'Reseeded with ${outcome.plan.excludedRowCount} row(s) left behind',
        ReseedVerdict.diverged =>
          'Diverged — ${outcome.divergedTables.length} table(s) differ',
        ReseedVerdict.notEnrolled => 'This device is not enrolled yet',
        ReseedVerdict.uploadIncomplete => 'Upload incomplete',
        ReseedVerdict.readOnlyProofFailed => 'Read-only proof failed',
      };

  String _verdictExplanation(ReseedOutcome outcome) =>
      switch (outcome.verdict) {
        ReseedVerdict.reseededAndConverged =>
          'Every entity the legacy store holds is on the spine, and reducing the '
              'server log from nothing produces exactly it. This report is the '
              'Phase-2 acceptance artifact — copy it.',
        ReseedVerdict.partiallyReseeded =>
          'What reached the spine is faithful, but some legacy rows could not be '
              'carried — a required column is NULL, or a value no codec accepts. '
              'They are listed under Not carried; fix them in the app and run '
              'again.',
        ReseedVerdict.diverged =>
          'Open a table below for the entity ids. `only_in_legacy` means an op '
              'never landed; `only_in_reduced` means the spine holds something '
              'this store does not; `held_back` means the row did not project.',
        ReseedVerdict.notEnrolled =>
          'Run the enrolment ceremony first: without a member credential there '
              'is nothing to author through, and without a pinned Root nothing '
              'can verify a control op.',
        ReseedVerdict.uploadIncomplete =>
          'Ops are still queued after the final flush, so the server does not '
              'hold everything this run authored. Get online and run again — the '
              'skip makes the retry cheap.',
        ReseedVerdict.readOnlyProofFailed =>
          'The legacy store or PowerSync\'s upload queue changed during the run, '
              'so this tool cannot vouch for its own answer. Nothing about the '
              'data is being claimed.',
      };

  Widget _areaExclusivityTile(ReseedPlan plan) => ExpansionTile(
        key: const Key('reseed_area_exclusivity'),
        title: const Text('Area exclusivity (ADR-0025)'),
        subtitle: Text(
          '${plan.resolutions.length} Outcome(s) held more than one Area — '
          '${plan.areaMembershipsConverted} membership(s) converted to Labels '
          '(${plan.labelsMinted} minted, ${plan.labelsMerged} merged)',
        ),
        children: [
          if (plan.resolutions.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text('Nothing to resolve.'),
            ),
          for (final resolution in plan.resolutions)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resolution.outcomeTitle ?? resolution.outcomeId,
                    key: Key('reseed_resolution_${resolution.outcomeId}'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text('kept Area: ${resolution.keptArea.name}'),
                  for (final conversion in resolution.converted)
                    Text(
                      'Area "${conversion.area.name}" → Label '
                      '"${conversion.label.name}" (${conversion.labelOrigin}'
                      '${conversion.collapsedOntoExistingMembership ? ', already held' : ''})',
                    ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'The kept Area is a deterministic provisional pick. The real '
              'resolution is yours, in the next Weekly Review — this list is '
              'that pass\'s worklist.',
            ),
          ),
        ],
      );

  Widget _tableTile(ReseedTableDiff table) => ExpansionTile(
        key: Key('reseed_table_${table.table}'),
        title: Text(table.table),
        subtitle: Text(
          'source ${table.plannedCount} / reduced ${table.reducedCount} / '
          'projected ${table.projectedRowCount}'
          '${table.converged ? ' — converged' : ' — ${table.differenceCount} difference(s)'}',
        ),
        trailing: Icon(
          table.converged ? Icons.check : Icons.priority_high,
          key: Key(
            'reseed_status_${table.table}_'
            '${table.converged ? 'converged' : 'diverged'}',
          ),
        ),
        children: [
          _idBlock('Only in the legacy store', table.onlyInLegacyIds,
              'reseed_only_legacy_${table.table}'),
          _idBlock('Only in reduced state', table.onlyInReducedIds,
              'reseed_only_reduced_${table.table}'),
          _idBlock('Different content', table.mismatchedIds,
              'reseed_mismatched_${table.table}'),
          _idBlock('Held back by the projector', table.heldBackIds,
              'reseed_held_back_${table.table}'),
          for (final anomaly in [
            ...table.legacyAnomalies,
            ...table.reducedAnomalies,
          ])
            ListTile(
              dense: true,
              title: Text('${anomaly.kind} — ${anomaly.column ?? '(row)'}'),
              subtitle: Text('${anomaly.rowId ?? '(no id)'}: ${anomaly.raw}'),
            ),
        ],
      );

  Widget _idBlock(String label, List<String> ids, String keyPrefix) {
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label (${ids.length})',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final id in ids) Text(id, key: Key('${keyPrefix}_$id')),
        ],
      ),
    );
  }
}
