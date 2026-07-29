/// The converge-verify diff: the local store's digests against the server's.
///
/// **Cutover tooling — removed by #556.**
///
/// Everything the check needs is injected, so the run under test is the run that
/// happens on the phone: production hands in the PowerSync database handle and
/// `getUploadQueueStats()`, a test hands in a Drift database and a counter. There
/// is no second code path.
///
/// Two properties are load-bearing and both are asserted rather than claimed:
///
/// * **Read-only by effect.** The run snapshots the local per-table digests and
///   the upload-queue count before and after, and publishes the comparison as
///   [ReadOnlyProof]. "It only issues SELECTs" is an assertion about code; this
///   is an observation about the store.
/// * **Nothing throws on odd data.** A refused value becomes an anomaly (see
///   `canonical_row.dart`), a NULL row id becomes a count, and a missing server
///   endpoint becomes a verdict — never an exception that costs the user their
///   only look at the store.
library;

import 'dart:convert';

import 'canonical_row.dart';

/// Reads every row of one table. `SELECT * FROM <table>`, deliberately
/// unfiltered: a row stranded at `user_id = 'local'` must show up as local-only
/// rather than being quietly excluded from the comparison.
typedef ConvergeRowSource = Future<List<Map<String, Object?>>> Function(
    String table);

/// The pending upload-queue count, or null where no sync engine is attached.
typedef UploadQueueCountReader = Future<int?> Function();

// --- the server's half ------------------------------------------------------

class ServerTableReport {
  const ServerTableReport({
    required this.count,
    required this.nullIdRowCount,
    required this.rows,
    required this.anomalies,
  });

  final int count;
  final int nullIdRowCount;
  final Map<String, String> rows;
  final List<ConvergeRowAnomaly> anomalies;

  factory ServerTableReport.fromJson(Map<String, dynamic> json) =>
      ServerTableReport(
        count: (json['count'] as num?)?.toInt() ?? 0,
        nullIdRowCount: (json['null_id_row_count'] as num?)?.toInt() ?? 0,
        rows: {
          for (final entry
              in (json['rows'] as Map<String, dynamic>? ?? const {}).entries)
            entry.key: entry.value as String,
        },
        anomalies: [
          for (final entry
              in (json['anomalies'] as List<dynamic>? ?? const []))
            ConvergeRowAnomaly(
              rowId: (entry as Map<String, dynamic>)['row_id'] as String?,
              column: entry['column'] as String,
              kind: entry['kind'] as String,
              raw: entry['raw'] as String?,
            ),
        ],
      );
}

class ServerConvergeReport {
  const ServerConvergeReport({
    required this.specVersion,
    required this.serverVersion,
    required this.generatedAt,
    required this.excludedColumns,
    required this.tables,
  });

  final int specVersion;
  final String serverVersion;
  final String generatedAt;
  final Map<String, List<String>> excludedColumns;
  final Map<String, ServerTableReport> tables;

  factory ServerConvergeReport.fromJson(Map<String, dynamic> json) =>
      ServerConvergeReport(
        specVersion: (json['spec_version'] as num?)?.toInt() ?? 0,
        serverVersion: json['server_version'] as String? ?? 'unknown',
        generatedAt: json['generated_at'] as String? ?? '',
        excludedColumns: {
          for (final entry in (json['excluded_columns'] as Map<String, dynamic>? ??
                  const {})
              .entries)
            entry.key: [
              for (final column in entry.value as List<dynamic>) column as String,
            ],
        },
        tables: {
          for (final entry
              in (json['tables'] as Map<String, dynamic>? ?? const {}).entries)
            entry.key:
                ServerTableReport.fromJson(entry.value as Map<String, dynamic>),
        },
      );
}

// --- the local half ---------------------------------------------------------

class LocalTableReport {
  const LocalTableReport({
    required this.count,
    required this.nullIdRowCount,
    required this.rows,
    required this.anomalies,
  });

  final int count;
  final int nullIdRowCount;
  final Map<String, String> rows;
  final List<ConvergeRowAnomaly> anomalies;

  String get mapDigest => convergeMapDigest(rows);
}

class LocalConvergeReport {
  const LocalConvergeReport({required this.tables});

  final Map<String, LocalTableReport> tables;

  /// One digest over every table's `id -> row_digest` map — the short form the
  /// read-only proof compares and the screen shows.
  String get digest => convergeMapDigest({
        for (final table in convergeVerifyTables)
          table: tables[table]?.mapDigest ?? '',
      });
}

/// Reads the whole local store and canonicalises it. Issues nothing but SELECTs.
Future<LocalConvergeReport> buildLocalConvergeReport(
  ConvergeRowSource readRows,
) async {
  final tables = <String, LocalTableReport>{};
  for (final table in convergeVerifyTables) {
    final rows = await readRows(table);
    final digests = <String, String>{};
    final anomalies = <ConvergeRowAnomaly>[];
    var nullIdRowCount = 0;
    for (final values in rows) {
      final rowId = values['id'];
      final canonical = canonicalRow(table, values);
      if (rowId is String) {
        digests[rowId] = canonical.digest;
      } else {
        nullIdRowCount++;
      }
      for (final anomaly in canonical.anomalies) {
        anomalies.add(anomaly.withRowId(rowId is String ? rowId : null));
      }
    }
    final sortedIds = digests.keys.toList()..sort();
    tables[table] = LocalTableReport(
      count: rows.length,
      nullIdRowCount: nullIdRowCount,
      rows: {for (final id in sortedIds) id: digests[id]!},
      anomalies: anomalies,
    );
  }
  return LocalConvergeReport(tables: tables);
}

// --- the diff ---------------------------------------------------------------

class TableDiff {
  const TableDiff({
    required this.table,
    required this.localCount,
    required this.serverCount,
    required this.localNullIdRowCount,
    required this.serverNullIdRowCount,
    required this.onlyLocalIds,
    required this.onlyServerIds,
    required this.mismatchedIds,
    required this.localAnomalies,
    required this.serverAnomalies,
  });

  final String table;
  final int localCount;
  final int serverCount;
  final int localNullIdRowCount;
  final int serverNullIdRowCount;

  /// Present on the device, absent from the server — an unsynced write, or a row
  /// stranded under the `'local'` user.
  final List<String> onlyLocalIds;

  /// Present on the server, absent from the device — a download the device never
  /// applied, or a local delete that never uploaded.
  final List<String> onlyServerIds;

  /// Same id both sides, different digest.
  final List<String> mismatchedIds;

  final List<ConvergeRowAnomaly> localAnomalies;
  final List<ConvergeRowAnomaly> serverAnomalies;

  /// A NULL row id has no identity to match on, so it cannot be shown to agree —
  /// it forces a non-converged table verdict rather than being a footnote. Same
  /// for an anomaly: a refused column value means this row's digest does not
  /// carry that column's content, so "equal digests" would be a weaker claim than
  /// it looks.
  bool get converged =>
      onlyLocalIds.isEmpty &&
      onlyServerIds.isEmpty &&
      mismatchedIds.isEmpty &&
      localNullIdRowCount == 0 &&
      serverNullIdRowCount == 0 &&
      localAnomalies.isEmpty &&
      serverAnomalies.isEmpty;

  int get differenceCount =>
      onlyLocalIds.length + onlyServerIds.length + mismatchedIds.length;
}

List<TableDiff> diffConvergeReports(
  LocalConvergeReport local,
  ServerConvergeReport server,
) {
  final diffs = <TableDiff>[];
  for (final table in convergeVerifyTables) {
    final localTable = local.tables[table] ??
        const LocalTableReport(
            count: 0, nullIdRowCount: 0, rows: {}, anomalies: []);
    final serverTable = server.tables[table] ??
        const ServerTableReport(
            count: 0, nullIdRowCount: 0, rows: {}, anomalies: []);
    final onlyLocal = <String>[];
    final mismatched = <String>[];
    for (final entry in localTable.rows.entries) {
      final serverDigest = serverTable.rows[entry.key];
      if (serverDigest == null) {
        onlyLocal.add(entry.key);
      } else if (serverDigest != entry.value) {
        mismatched.add(entry.key);
      }
    }
    final onlyServer = [
      for (final id in serverTable.rows.keys)
        if (!localTable.rows.containsKey(id)) id,
    ];
    diffs.add(TableDiff(
      table: table,
      localCount: localTable.count,
      serverCount: serverTable.count,
      localNullIdRowCount: localTable.nullIdRowCount,
      serverNullIdRowCount: serverTable.nullIdRowCount,
      onlyLocalIds: onlyLocal..sort(),
      onlyServerIds: onlyServer..sort(),
      mismatchedIds: mismatched..sort(),
      localAnomalies: localTable.anomalies,
      serverAnomalies: serverTable.anomalies,
    ));
  }
  return diffs;
}

// --- column-level diff ------------------------------------------------------

/// One column where two canonical rows disagree.
class ColumnDifference {
  const ColumnDifference({
    required this.column,
    required this.local,
    required this.server,
  });

  final String column;

  /// The canonical *encoding* of each side's value, not the raw value — that is
  /// what the digest was taken over, so it is what a mismatch is about.
  final String local;
  final String server;
}

/// Which columns two canonical rows disagree on.
///
/// This is what turns an opaque digest mismatch into something a reviewer can
/// act on — and, just as importantly, what distinguishes a real divergence from
/// a bug in this tool's own normaliser.
List<ColumnDifference> compareCanonicalRows({
  required String table,
  required String localCanonical,
  required String serverCanonical,
}) {
  final manifest = canonicalRowManifest[table]!;
  final List<dynamic> localValues;
  final List<dynamic> serverValues;
  try {
    localValues = jsonDecode(localCanonical) as List<dynamic>;
    serverValues = jsonDecode(serverCanonical) as List<dynamic>;
  } on FormatException {
    return [
      ColumnDifference(
        column: '<whole row>',
        local: localCanonical,
        server: serverCanonical,
      ),
    ];
  }
  if (localValues.length != manifest.length ||
      serverValues.length != manifest.length) {
    return [
      ColumnDifference(
        column: '<column count>',
        local: '${localValues.length} values',
        server: '${serverValues.length} values',
      ),
    ];
  }
  final differences = <ColumnDifference>[];
  for (var index = 0; index < manifest.length; index++) {
    final local = jsonEncode(localValues[index]);
    final server = jsonEncode(serverValues[index]);
    if (local != server) {
      differences.add(ColumnDifference(
        column: manifest[index].$1,
        local: local,
        server: server,
      ));
    }
  }
  return differences;
}

// --- the read-only proof ----------------------------------------------------

/// The evidence that the run changed nothing, gathered by observation.
class ReadOnlyProof {
  const ReadOnlyProof({
    required this.localDigestBefore,
    required this.localDigestAfter,
    required this.uploadQueueCountBefore,
    required this.uploadQueueCountAfter,
  });

  final String localDigestBefore;
  final String localDigestAfter;

  /// Null where no sync engine is attached (local-only mode) — unknown, which is
  /// not the same as zero and is not allowed to read as proof.
  final int? uploadQueueCountBefore;
  final int? uploadQueueCountAfter;

  bool get digestsUnchanged => localDigestBefore == localDigestAfter;

  bool get uploadQueueUnchanged =>
      uploadQueueCountBefore == uploadQueueCountAfter;

  bool get unchanged => digestsUnchanged && uploadQueueUnchanged;

  /// The line the screen renders, so the claim is visible and not just tested.
  String get summaryLine {
    final queueBefore = uploadQueueCountBefore?.toString() ?? 'n/a';
    final queueAfter = uploadQueueCountAfter?.toString() ?? 'n/a';
    final verdict = unchanged ? 'unchanged' : 'CHANGED';
    return 'Read-only proof: store digest $verdict '
        '(${_short(localDigestBefore)} → ${_short(localDigestAfter)}), '
        'upload queue $queueBefore → $queueAfter';
  }

  static String _short(String digest) =>
      digest.length <= 12 ? digest : digest.substring(0, 12);
}

// --- preconditions ----------------------------------------------------------

/// What has to be true before "every table converged" means anything.
///
/// A pending upload or a recorded dead letter means the device is holding writes
/// the server has never seen, so digests that differ are expected rather than
/// evidence — and digests that agree are luck.
class ConvergePreconditions {
  const ConvergePreconditions({
    required this.uploadQueueCount,
    required this.deadLetterCount,
    required this.syncStateLabel,
  });

  final int? uploadQueueCount;
  final int deadLetterCount;
  final String syncStateLabel;

  bool get fullySynced => uploadQueueCount == 0 && deadLetterCount == 0;
}

// --- the run ----------------------------------------------------------------

enum ConvergeVerdict {
  converged,
  diverged,

  /// Pending uploads or dead letters: the premise of the check does not hold yet.
  notFullySynced,

  /// The endpoint 404s — an older server. Main stays deployable in either merge
  /// order, so this is a state to render, not a crash.
  serverNotDeployed,

  /// The server implements a different `spec/converge_verify/` version, so its
  /// digests are not comparable with ours. Refusing is the only honest answer.
  specVersionMismatch,

  /// The run itself changed the store, or could not prove that it had not. The
  /// tool is not trustworthy in this state and says so instead of reporting a
  /// verdict about the data.
  readOnlyProofFailed,
}

class ConvergeVerifyOutcome {
  const ConvergeVerifyOutcome({
    required this.verdict,
    required this.local,
    required this.server,
    required this.tables,
    required this.readOnlyProof,
    required this.preconditions,
  });

  final ConvergeVerdict verdict;
  final LocalConvergeReport local;
  final ServerConvergeReport? server;
  final List<TableDiff> tables;
  final ReadOnlyProof readOnlyProof;
  final ConvergePreconditions preconditions;

  bool get converged => verdict == ConvergeVerdict.converged;

  List<TableDiff> get divergedTables =>
      [for (final table in tables) if (!table.converged) table];

  /// The archival form: what gets copied to the clipboard and printed to logcat
  /// so a run can be pasted into the issue.
  Map<String, Object?> toJson() => {
        'verdict': verdict.name,
        'spec_version': convergeVerifySpecVersion,
        'server_version': server?.serverVersion,
        'server_generated_at': server?.generatedAt,
        'excluded_columns': excludedColumnsReport(),
        'read_only_proof': {
          'local_digest_before': readOnlyProof.localDigestBefore,
          'local_digest_after': readOnlyProof.localDigestAfter,
          'upload_queue_count_before': readOnlyProof.uploadQueueCountBefore,
          'upload_queue_count_after': readOnlyProof.uploadQueueCountAfter,
          'unchanged': readOnlyProof.unchanged,
        },
        'preconditions': {
          'upload_queue_count': preconditions.uploadQueueCount,
          'dead_letter_count': preconditions.deadLetterCount,
          'sync_state': preconditions.syncStateLabel,
        },
        'tables': {
          for (final table in tables)
            table.table: {
              'converged': table.converged,
              'local_count': table.localCount,
              'server_count': table.serverCount,
              'local_null_id_row_count': table.localNullIdRowCount,
              'server_null_id_row_count': table.serverNullIdRowCount,
              'only_local_ids': table.onlyLocalIds,
              'only_server_ids': table.onlyServerIds,
              'mismatched_ids': table.mismatchedIds,
              'local_anomalies': [
                for (final anomaly in table.localAnomalies) anomaly.toJson(),
              ],
              'server_anomalies': [
                for (final anomaly in table.serverAnomalies) anomaly.toJson(),
              ],
            },
        },
      };
}

/// One converge-verify run, end to end.
///
/// [fetchServerReport] returns null when the endpoint is absent (an older
/// server); anything else it throws propagates to the caller, which is a real
/// failure worth showing rather than swallowing.
Future<ConvergeVerifyOutcome> runConvergeVerify({
  required ConvergeRowSource readRows,
  required Future<ServerConvergeReport?> Function() fetchServerReport,
  required UploadQueueCountReader uploadQueueCount,
  required Future<int> Function() deadLetterCount,
  String syncStateLabel = 'unknown',
}) async {
  // Order matters: both snapshots must bracket everything the run does, so the
  // proof covers the server fetch too, not just the local read.
  final queueBefore = await uploadQueueCount();
  final localBefore = await buildLocalConvergeReport(readRows);
  final server = await fetchServerReport();
  final localAfter = await buildLocalConvergeReport(readRows);
  final queueAfter = await uploadQueueCount();

  final proof = ReadOnlyProof(
    localDigestBefore: localBefore.digest,
    localDigestAfter: localAfter.digest,
    uploadQueueCountBefore: queueBefore,
    uploadQueueCountAfter: queueAfter,
  );
  final preconditions = ConvergePreconditions(
    uploadQueueCount: queueAfter,
    deadLetterCount: await deadLetterCount(),
    syncStateLabel: syncStateLabel,
  );

  final tables =
      server == null ? <TableDiff>[] : diffConvergeReports(localBefore, server);

  return ConvergeVerifyOutcome(
    verdict: _verdictFor(
      server: server,
      proof: proof,
      preconditions: preconditions,
      tables: tables,
    ),
    local: localBefore,
    server: server,
    tables: tables,
    readOnlyProof: proof,
    preconditions: preconditions,
  );
}

/// Worst-news-first: a fault in the tool outranks a fault in the data, and an
/// unmet premise outranks a divergence it would explain anyway.
ConvergeVerdict _verdictFor({
  required ServerConvergeReport? server,
  required ReadOnlyProof proof,
  required ConvergePreconditions preconditions,
  required List<TableDiff> tables,
}) {
  if (!proof.unchanged) return ConvergeVerdict.readOnlyProofFailed;
  if (server == null) return ConvergeVerdict.serverNotDeployed;
  if (server.specVersion != convergeVerifySpecVersion) {
    return ConvergeVerdict.specVersionMismatch;
  }
  if (!preconditions.fullySynced) return ConvergeVerdict.notFullySynced;
  if (tables.any((table) => !table.converged)) return ConvergeVerdict.diverged;
  return ConvergeVerdict.converged;
}
