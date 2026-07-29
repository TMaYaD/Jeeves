/// The converge-verify differ over a real local store.
///
/// Cutover tooling — removed by #556.
///
/// The row source is the production one: `SELECT * FROM <table>`, unfiltered,
/// against a real SQLite database with the production table names. In production
/// those names resolve to PowerSync views over `ps_data__*`; here they are Drift's
/// own tables. The SQL, the column names and the stored value shapes are the
/// same — including Drift's space-before-offset timestamps, which is exactly the
/// text the phone holds (docs/SYNC.md).
///
/// The automated end-to-end acceptance case lives here: a seeded local-only row,
/// a seeded server-only row and a seeded content difference must each be detected
/// and named, per table, with row ids.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/cutover/converge_verify/canonical_row.dart';
import 'package:jeeves/cutover/converge_verify/converge_differ.dart';
import 'package:jeeves/database/gtd_database.dart';

import '../test_helpers.dart';

const String _userId = 'user-a';

GtdDatabase _openInMemory() => GtdDatabase(NativeDatabase.memory());

/// The production row source: whole tables, no WHERE clause.
ConvergeRowSource _rowSource(GtdDatabase db, {List<String>? log}) =>
    (table) async {
      log?.add(table);
      final rows = await db.customSelect('SELECT * FROM $table').get();
      return [for (final row in rows) row.data];
    };

/// Re-shapes a locally-stored row the way Postgres would hand it back:
/// `timestamptz` as a `DateTime`, `boolean` as a real bool.
///
/// The two shapes agreeing on a digest is pinned by the frozen vectors; this
/// helper is how the differ test gets a *server* report that is honestly built
/// from the server's value types rather than copied from the local one.
Map<String, Object?> _serverShape(String table, Map<String, Object?> local) {
  final out = <String, Object?>{};
  for (final (column, kind) in canonicalRowManifest[table]!) {
    final value = local[column];
    if (value == null) {
      out[column] = null;
      continue;
    }
    switch (kind) {
      case timestampUtcMs:
        // A value the rules refuse has no DateTime to become; pass it through so
        // the helper models the server's types where it can and never throws.
        final instant = parseTimestampUtcMs(value);
        out[column] = instant == null ? value : DateTime.parse(instant);
      case booleanAsInt:
        out[column] = value == 1;
      default:
        out[column] = value;
    }
  }
  return out;
}

/// A server report mirroring the local store, optionally perturbed.
///
/// [drop] removes ids the server should not have (so they read as local-only),
/// [extra] adds server-only rows, and [corrupt] rewrites a row's digest (so it
/// reads as a content difference).
Future<ServerConvergeReport> _serverReportMirroring(
  GtdDatabase db, {
  Map<String, Set<String>> drop = const {},
  Map<String, Map<String, String>> extra = const {},
  Map<String, Set<String>> corrupt = const {},
  Map<String, int> nullIdRowCounts = const {},
  Map<String, List<ConvergeRowAnomaly>> anomalies = const {},
  int specVersion = convergeVerifySpecVersion,
  Set<String> excludeUserIds = const {'local'},
}) async {
  final tables = <String, ServerTableReport>{};
  for (final table in convergeVerifyTables) {
    final rows = await db.customSelect('SELECT * FROM $table').get();
    final digests = <String, String>{};
    for (final row in rows) {
      final values = row.data;
      final rowId = values['id'];
      if (rowId is! String) continue;
      // The server only ever holds rows for a real signed-in user, so a row
      // stranded under the local pseudo-user is absent by construction.
      if (excludeUserIds.contains(values['user_id'])) continue;
      if (drop[table]?.contains(rowId) ?? false) continue;
      digests[rowId] = (corrupt[table]?.contains(rowId) ?? false)
          ? 'deadbeef' * 8
          : canonicalRow(table, _serverShape(table, values)).digest;
    }
    digests.addAll(extra[table] ?? const {});
    final nullIds = nullIdRowCounts[table] ?? 0;
    tables[table] = ServerTableReport(
      count: digests.length + nullIds,
      nullIdRowCount: nullIds,
      rows: digests,
      anomalies: anomalies[table] ?? const [],
    );
  }
  return ServerConvergeReport(
    specVersion: specVersion,
    serverVersion: '1.2.3-test',
    generatedAt: '2026-07-29T00:00:00.000Z',
    excludedColumns: excludedColumnsReport(),
    tables: tables,
  );
}

Future<void> _seedConvergedStore(GtdDatabase db, {String userId = _userId}) async {
  final createdAt = DateTime(2026, 4, 29, 9, 15);
  await db.into(db.todos).insert(TodosCompanion(
        id: const Value('todo-1'),
        title: const Value('Ship the cutover check'),
        userId: Value(userId),
        createdAt: Value(createdAt),
        clarified: const Value(true),
        intent: const Value('next'),
        timeEstimate: const Value(25),
        energyLevel: const Value('medium'),
        lastClarifiedAt: Value(createdAt),
      ));
  await db.into(db.tags).insert(TagsCompanion(
        id: const Value('tag-1'),
        name: const Value('@work'),
        type: const Value('context'),
        userId: Value(userId),
      ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: const Value('tt-1'),
        todoId: const Value('todo-1'),
        tagId: const Value('tag-1'),
        userId: Value(userId),
      ));
  await db.into(db.actions).insert(ActionsCompanion(
        id: const Value('action-1'),
        outcomeId: const Value('todo-1'),
        userId: Value(userId),
        actionText: const Value('Draft the outline'),
        role: const Value('current'),
        createdAt: Value(createdAt),
      ));
  await db.into(db.captures).insert(CapturesCompanion(
        id: const Value('capture-1'),
        title: const Value('Call the plumber'),
        userId: Value(userId),
        createdAt: Value(createdAt),
      ));
  await db.into(db.focusSessions).insert(FocusSessionsCompanion(
        id: const Value('fs-1'),
        userId: Value(userId),
        startedAt: Value(createdAt.toUtc().toIso8601String()),
      ));
  await db.into(db.timeLogs).insert(TimeLogsCompanion(
        id: const Value('tl-1'),
        userId: Value(userId),
        taskId: const Value('todo-1'),
        actionId: const Value('action-1'),
        startedAt: Value(createdAt.toUtc().toIso8601String()),
        focusSessionId: const Value('fs-1'),
      ));
  await db.into(db.userPreferences).insert(UserPreferencesCompanion(
        id: const Value('pref-1'),
        userId: Value(userId),
        key: const Value('daily_planning_time'),
        value: const Value('{"hour":8,"minute":0}'),
        updatedAt: Value(createdAt.toUtc().toIso8601String()),
      ));
}

Future<ConvergeVerifyOutcome> _run(
  GtdDatabase db, {
  ServerConvergeReport? server,
  int uploadQueueCount = 0,
  int deadLetterCount = 0,
  List<String>? readLog,
}) =>
    runConvergeVerify(
      readRows: _rowSource(db, log: readLog),
      fetchServerReport: () async => server,
      uploadQueueCount: () async => uploadQueueCount,
      deadLetterCount: () async => deadLetterCount,
      syncStateLabel: 'synced',
    );

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    db = _openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  test('a fully-synced store reports every table converged', () async {
    await _seedConvergedStore(db);
    final outcome = await _run(db, server: await _serverReportMirroring(db));

    expect(outcome.verdict, ConvergeVerdict.converged);
    expect(outcome.divergedTables, isEmpty);
    expect(outcome.tables.length, convergeVerifyTables.length);
    for (final table in outcome.tables) {
      expect(table.converged, isTrue, reason: table.table);
      expect(table.localCount, table.serverCount, reason: table.table);
    }
    // The store is not empty — an all-zero comparison would pass vacuously.
    expect(
      outcome.tables.where((table) => table.localCount > 0).length,
      greaterThanOrEqualTo(8),
    );
  });

  test('a seeded divergence is detected and named per table with row ids',
      () async {
    await _seedConvergedStore(db);
    // Local-only: the server has no row for this id (an unsynced write).
    // Server-only: the device never applied a downloaded row, or a delete never
    // uploaded. Content difference: same id, different column values.
    final server = await _serverReportMirroring(
      db,
      drop: const {'todos': {'todo-1'}},
      extra: {
        'tags': {'tag-server-only': 'f' * 64},
      },
      corrupt: const {'actions': {'action-1'}},
    );
    final outcome = await _run(db, server: server);

    expect(outcome.verdict, ConvergeVerdict.diverged);
    final byTable = {for (final table in outcome.tables) table.table: table};

    expect(byTable['todos']!.onlyLocalIds, ['todo-1']);
    expect(byTable['todos']!.onlyServerIds, isEmpty);
    expect(byTable['todos']!.mismatchedIds, isEmpty);

    expect(byTable['tags']!.onlyServerIds, ['tag-server-only']);
    expect(byTable['tags']!.onlyLocalIds, isEmpty);

    expect(byTable['actions']!.mismatchedIds, ['action-1']);
    expect(byTable['actions']!.onlyLocalIds, isEmpty);

    // Untouched tables must not be dragged into the verdict.
    expect(byTable['captures']!.converged, isTrue);
    expect(byTable['todo_tags']!.converged, isTrue);
    expect(
      {for (final table in outcome.divergedTables) table.table},
      {'todos', 'tags', 'actions'},
    );
  });

  test('a row stranded under the local pseudo-user surfaces as local-only',
      () async {
    await _seedConvergedStore(db);
    // A row that never synced because it was written before sign-in. The row
    // source is deliberately unfiltered so this cannot hide.
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('todo-stranded'),
          title: const Value('Written before sign-in'),
          userId: const Value('local'),
          createdAt: Value(DateTime(2026, 4, 28)),
          clarified: const Value(true),
          intent: const Value('next'),
        ));

    final outcome = await _run(db, server: await _serverReportMirroring(db));

    final todos =
        outcome.tables.firstWhere((table) => table.table == 'todos');
    expect(todos.onlyLocalIds, ['todo-stranded']);
    expect(todos.localCount, 2);
    expect(todos.serverCount, 1);
    expect(outcome.verdict, ConvergeVerdict.diverged);
  });

  test('a server NULL-id row forces a non-converged table verdict', () async {
    await _seedConvergedStore(db);
    // A junction row whose id Postgres never filled has no identity to match on,
    // so it can never be shown to agree — it is not a footnote on an otherwise
    // green table.
    final server = await _serverReportMirroring(
      db,
      nullIdRowCounts: const {'todo_tags': 1},
    );
    final outcome = await _run(db, server: server);

    final junction =
        outcome.tables.firstWhere((table) => table.table == 'todo_tags');
    expect(junction.serverNullIdRowCount, 1);
    expect(junction.onlyLocalIds, isEmpty);
    expect(junction.onlyServerIds, isEmpty);
    expect(junction.mismatchedIds, isEmpty);
    expect(junction.converged, isFalse);
    expect(outcome.verdict, ConvergeVerdict.diverged);
  });

  test('a server anomaly forces a non-converged table verdict', () async {
    await _seedConvergedStore(db);
    final server = await _serverReportMirroring(
      db,
      anomalies: const {
        'todos': [
          ConvergeRowAnomaly(
            rowId: 'todo-1',
            column: 'priority',
            kind: invalidInteger,
            raw: 'high',
          ),
        ],
      },
    );
    final outcome = await _run(db, server: server);

    final todos = outcome.tables.firstWhere((table) => table.table == 'todos');
    // Digests agree, but one column's content is not in them, so "converged"
    // would claim more than the digests support.
    expect(todos.mismatchedIds, isEmpty);
    expect(todos.converged, isFalse);
    expect(todos.serverAnomalies.single.column, 'priority');
  });

  group('read-only by effect', () {
    test('the run leaves the store and the upload queue untouched', () async {
      await _seedConvergedStore(db);
      final before = await db.customSelect('SELECT * FROM todos').get();
      var queueReads = 0;

      final outcome = await runConvergeVerify(
        readRows: _rowSource(db),
        fetchServerReport: () async => _serverReportMirroring(db),
        uploadQueueCount: () async {
          queueReads++;
          return 0;
        },
        deadLetterCount: () async => 0,
      );

      expect(outcome.readOnlyProof.digestsUnchanged, isTrue);
      expect(outcome.readOnlyProof.uploadQueueUnchanged, isTrue);
      expect(outcome.readOnlyProof.unchanged, isTrue);
      // The proof brackets the whole run, server fetch included.
      expect(queueReads, 2);

      final after = await db.customSelect('SELECT * FROM todos').get();
      expect(
        [for (final row in after) row.data],
        [for (final row in before) row.data],
      );
      expect(
        outcome.readOnlyProof.summaryLine,
        contains('store digest unchanged'),
      );
    });

    test('a store that changes mid-run is reported, not papered over', () async {
      await _seedConvergedStore(db);
      var reads = 0;
      final outcome = await runConvergeVerify(
        readRows: (table) async {
          final rows = await db.customSelect('SELECT * FROM $table').get();
          return [for (final row in rows) row.data];
        },
        fetchServerReport: () async {
          // Stand in for a hypothetical write inside the run: whatever the cause,
          // the proof must fail rather than the verdict being trusted.
          reads++;
          await db.into(db.tags).insert(const TagsCompanion(
                id: Value('tag-appeared'),
                name: Value('@later'),
                type: Value('context'),
                userId: Value(_userId),
              ));
          return null;
        },
        uploadQueueCount: () async => 0,
        deadLetterCount: () async => 0,
      );

      expect(reads, 1);
      expect(outcome.readOnlyProof.digestsUnchanged, isFalse);
      // A tool that cannot prove it was harmless says so instead of reporting a
      // verdict about the data — even though the server was also missing.
      expect(outcome.verdict, ConvergeVerdict.readOnlyProofFailed);
      expect(outcome.readOnlyProof.summaryLine, contains('CHANGED'));
    });

    test('a growing upload queue fails the proof', () async {
      await _seedConvergedStore(db);
      var reads = 0;
      final outcome = await runConvergeVerify(
        readRows: _rowSource(db),
        fetchServerReport: () async => _serverReportMirroring(db),
        uploadQueueCount: () async => reads++ == 0 ? 0 : 1,
        deadLetterCount: () async => 0,
      );
      expect(outcome.readOnlyProof.uploadQueueUnchanged, isFalse);
      expect(outcome.verdict, ConvergeVerdict.readOnlyProofFailed);
    });

    test('an unknown queue count is not read as proof of zero', () async {
      const proof = ReadOnlyProof(
        localDigestBefore: 'a',
        localDigestAfter: 'a',
        uploadQueueCountBefore: null,
        uploadQueueCountAfter: null,
      );
      expect(proof.unchanged, isTrue);
      expect(proof.summaryLine, contains('n/a'));
      const preconditions = ConvergePreconditions(
        uploadQueueCount: null,
        deadLetterCount: 0,
        syncStateLabel: 'local only',
      );
      expect(preconditions.fullySynced, isFalse);
    });
  });

  group('preconditions gate the verdict', () {
    test('a pending upload means the premise does not hold yet', () async {
      await _seedConvergedStore(db);
      final outcome = await _run(
        db,
        server: await _serverReportMirroring(db),
        uploadQueueCount: 1,
      );
      // Every digest agrees, and that is still not a converged verdict: the
      // device is holding a write the server has never seen.
      expect(outcome.divergedTables, isEmpty);
      expect(outcome.verdict, ConvergeVerdict.notFullySynced);
    });

    test('a dead letter means the premise does not hold yet', () async {
      await _seedConvergedStore(db);
      final outcome = await _run(
        db,
        server: await _serverReportMirroring(db),
        deadLetterCount: 1,
      );
      expect(outcome.verdict, ConvergeVerdict.notFullySynced);
      expect(outcome.preconditions.deadLetterCount, 1);
    });
  });

  group('server skew', () {
    test('a missing endpoint is a state, not a crash', () async {
      await _seedConvergedStore(db);
      final outcome = await _run(db, server: null);
      expect(outcome.verdict, ConvergeVerdict.serverNotDeployed);
      expect(outcome.tables, isEmpty);
      // The local half still computed, so the screen has something to show.
      expect(outcome.local.tables['todos']!.count, 1);
    });

    test('a different spec version is refused rather than compared', () async {
      await _seedConvergedStore(db);
      final server = await _serverReportMirroring(db, specVersion: 99);
      final outcome = await _run(db, server: server);
      expect(outcome.verdict, ConvergeVerdict.specVersionMismatch);
    });
  });

  test('every synced table is read exactly once per local report', () async {
    await _seedConvergedStore(db);
    final log = <String>[];
    await _run(db, server: await _serverReportMirroring(db), readLog: log);
    // Two local reports per run — the before/after pair the proof compares.
    expect(log.length, convergeVerifyTables.length * 2);
    expect(log.toSet(), convergeVerifyTables.toSet());
  });

  test('the archival JSON carries the ids a reviewer needs', () async {
    await _seedConvergedStore(db);
    final server = await _serverReportMirroring(
      db,
      drop: const {'todos': {'todo-1'}},
    );
    final json = (await _run(db, server: server)).toJson();

    expect(json['verdict'], 'diverged');
    expect(json['server_version'], '1.2.3-test');
    final tables = json['tables']! as Map<String, Object?>;
    final todos = tables['todos']! as Map<String, Object?>;
    expect(todos['only_local_ids'], ['todo-1']);
    expect(todos['converged'], isFalse);
    expect(
      (json['read_only_proof']! as Map<String, Object?>)['unchanged'],
      isTrue,
    );
    expect(json['excluded_columns'], excludedColumnsReport());
  });

  test('an unparseable local timestamp becomes an anomaly, not an exception',
      () async {
    await _seedConvergedStore(db);
    // The local store is text, so a legacy or foreign shape is representable in a
    // way Postgres' timestamptz never is. It must not cost the user the report.
    await db.customStatement(
      "UPDATE todos SET created_at = '30/04/2026 00:00' WHERE id = 'todo-1'",
    );

    final outcome = await _run(db, server: await _serverReportMirroring(db));
    final todos = outcome.local.tables['todos']!;
    expect(todos.anomalies.single.column, 'created_at');
    expect(todos.anomalies.single.kind, unparseableTimestamp);
    expect(todos.anomalies.single.rowId, 'todo-1');
    expect(todos.rows.containsKey('todo-1'), isTrue);
  });
}
