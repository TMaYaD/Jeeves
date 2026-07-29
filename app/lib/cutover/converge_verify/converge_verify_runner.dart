/// Wires the converge-verify run to the real device: PowerSync's store, the
/// backend, and the local dead-letter table.
///
/// **Cutover tooling — removed by #556.**
///
/// The screen depends on [ConvergeVerifyRunner], never on PowerSync or Dio
/// directly, so a widget test scripts outcomes without an engine while the
/// production path stays the one the differ tests exercise.
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../../database/gtd_database.dart';
import '../../providers/database_provider.dart';
import '../../providers/powersync_provider.dart';
import '../../services/api_service.dart';
import 'canonical_row.dart';
import 'converge_differ.dart';

/// One row's canonical string on each side. A null side means "no row here".
class RowComparison {
  const RowComparison({
    required this.id,
    required this.localCanonical,
    required this.serverCanonical,
  });

  final String id;
  final String? localCanonical;
  final String? serverCanonical;

  List<ColumnDifference> differencesFor(String table) {
    final local = localCanonical;
    final server = serverCanonical;
    if (local == null || server == null) return const [];
    return compareCanonicalRows(
      table: table,
      localCanonical: local,
      serverCanonical: server,
    );
  }
}

abstract class ConvergeVerifyRunner {
  Future<ConvergeVerifyOutcome> run({required String syncStateLabel});

  /// Both sides' canonical strings for [ids], so a digest mismatch can be read
  /// column by column.
  Future<List<RowComparison>> compareRows(String table, List<String> ids);
}

/// The route paths the report and detail endpoints live at, in one place so the
/// 404-means-skew check and the request agree.
const String convergeVerifyReportPath = '/converge-verify/report';
const String convergeVerifyRowsPath = '/converge-verify/rows';

class RiverpodConvergeVerifyRunner implements ConvergeVerifyRunner {
  RiverpodConvergeVerifyRunner(this._ref);

  final Ref _ref;

  Future<ps.PowerSyncDatabase> get _powerSync =>
      _ref.read(powerSyncInstanceProvider.future);

  GtdDatabase get _drift => _ref.read(databaseProvider);

  ApiService get _api => _ref.read(apiServiceProvider);

  Future<List<Map<String, Object?>>> _readRows(String table) async {
    // Unfiltered on purpose: a row stranded at `user_id = 'local'` must show up
    // as local-only rather than being quietly excluded from the comparison.
    final result = await (await _powerSync).getAll('SELECT * FROM $table');
    return [for (final row in result) Map<String, Object?>.of(row)];
  }

  Future<int?> _uploadQueueCount() async {
    final stats = await (await _powerSync).getUploadQueueStats();
    return stats.count;
  }

  Future<int> _deadLetterCount() async {
    // A one-shot read, not `watchSyncDeadLetterCount()`: a live Drift watch
    // reached from a UI callback keeps a pending timer alive (docs/TESTING.md).
    final row = await _drift
        .customSelect('SELECT COUNT(*) AS row_count FROM sync_dead_letters')
        .getSingle();
    return row.read<int>('row_count');
  }

  /// Null when the endpoint 404s — an older server that has not picked up this
  /// deploy yet. Main stays deployable in either merge order, so the screen
  /// renders that state instead of the run failing.
  Future<ServerConvergeReport?> _fetchServerReport() async {
    try {
      final body = await _api.get(convergeVerifyReportPath);
      return ServerConvergeReport.fromJson(body);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<ConvergeVerifyOutcome> run({required String syncStateLabel}) =>
      runConvergeVerify(
        readRows: _readRows,
        fetchServerReport: _fetchServerReport,
        uploadQueueCount: _uploadQueueCount,
        deadLetterCount: _deadLetterCount,
        syncStateLabel: syncStateLabel,
      );

  @override
  Future<List<RowComparison>> compareRows(
    String table,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final localRows = await (await _powerSync).getAll(
      'SELECT * FROM $table WHERE id IN ($placeholders)',
      ids,
    );
    final localCanonical = <String, String>{
      for (final row in localRows)
        if (row['id'] case final String id)
          id: canonicalRow(table, Map<String, Object?>.of(row)).canonical,
    };

    var serverCanonical = <String, String>{};
    try {
      final body = await _api.get(
        '$convergeVerifyRowsPath?table=$table&ids=${ids.join(',')}',
      );
      serverCanonical = {
        for (final entry
            in (body['rows'] as Map<String, dynamic>? ?? const {}).entries)
          entry.key: entry.value as String,
      };
    } on DioException {
      // The detail route is a convenience over the report; losing it must not
      // cost the ids the report already established.
      serverCanonical = const {};
    }

    return [
      for (final id in ids)
        RowComparison(
          id: id,
          localCanonical: localCanonical[id],
          serverCanonical: serverCanonical[id],
        ),
    ];
  }
}

final convergeVerifyRunnerProvider = Provider<ConvergeVerifyRunner>(
  RiverpodConvergeVerifyRunner.new,
);
