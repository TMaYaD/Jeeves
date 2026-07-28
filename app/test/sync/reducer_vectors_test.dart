/// The reducer against `spec/sync/reducer_v1_vectors.json`.
///
/// The vectors are shared with the backend so field-grain LWW is pinned
/// identically on both sides of any future server-side tooling; today the Dart
/// reducer is their only consumer, and they are what stops a "harmless"
/// tweak to the merge rules from silently changing what converges.
///
/// Three optional per-case keys, added by #550 (see the file's `$case_schema`):
///
/// * `permute` — apply the ops in **every** order and assert the reduced state
///   is identical across all of them. A values-only pairwise case cannot catch
///   an associativity failure, which is exactly what a non-LWW merge strategy
///   can lose (ADR-0030).
/// * `expected_clocks` — the stored per-field HLC, asserted against
///   `field_clocks` whether or not the entity is visible. A strategy whose
///   clock joins independently of its value has no other observable surface.
/// * `strategy_overrides` — a preference key's strategy, for keys with no
///   production registration (today only `set_merge`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'harness/permutations.dart';
import 'vectors.dart';

MergeStrategyRegistry _registryFor(Map<String, dynamic> testCase) {
  final overrides = testCase['strategy_overrides'] as Map<String, dynamic>?;
  if (overrides == null) return const MergeStrategyRegistry();
  return MergeStrategyRegistry(
    preferenceKeyOverrides: {
      for (final entry in overrides.entries)
        entry.key: mergeStrategiesByName[entry.value as String]!,
    },
  );
}

/// The stored per-field clocks, shaped like the vectors' `expected_clocks`.
Future<Map<String, Map<String, Map<String, List<Object>>>>> _readClocks(
  SyncDatabase database,
) async {
  final rows = await database.select(database.fieldClocks).get();
  final clocks = <String, Map<String, Map<String, List<Object>>>>{};
  for (final row in rows) {
    ((clocks[row.collection] ??= {})[row.entityId] ??= {})[row.field] = [
      row.wallMs,
      row.counter,
      row.memberIdHex,
    ];
  }
  return clocks;
}

void main() {
  final document = reducerVectors();
  final localNowMs = document['local_now_ms'] as int;
  final futureSkewBoundMs = document['future_skew_bound_ms'] as int;

  test('the skew bound in the vectors is the reducer default', () {
    expect(futureSkewBoundMs, defaultFutureSkewBoundMs);
  });

  Future<void> runOrder(
    Map<String, dynamic> testCase,
    List<Map<String, dynamic>> ops,
    String orderLabel,
  ) async {
    // One fresh in-memory store per permutation; none of them share an
    // executor, so drift's shared-executor warning does not apply.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final registry = CollectionRegistry(database);
    final reducer = Reducer(
      database,
      nowMs: () => localNowMs,
      futureSkewBoundMs: futureSkewBoundMs,
      strategies: _registryFor(testCase),
    );

    final quarantined = <String>[];
    for (final op in ops) {
      final payload = OpPayload.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(op['payload']))),
      );
      try {
        await reducer.apply(
          payload,
          authorMemberIdHex: op['author_member_id_hex'] as String,
        );
      } on SyncRejection catch (rejection) {
        quarantined.add(rejection.reason.code);
      }
    }

    if (orderLabel.isEmpty) {
      // Quarantine is a per-arrival fact, so it is only asserted in file order.
      expect(quarantined, testCase['expected_quarantine_reasons']);
    }

    final expectedState = testCase['expected_entities'] as Map<String, dynamic>;
    for (final collection in expectedState.keys) {
      final actual = await registry.register(collection).readAll();
      expect(
        actual,
        expectedState[collection],
        reason: 'collection $collection$orderLabel',
      );
    }

    final expectedClocks = testCase['expected_clocks'] as Map<String, dynamic>?;
    if (expectedClocks != null) {
      final actualClocks = await _readClocks(database);
      expect(actualClocks, expectedClocks, reason: 'field clocks$orderLabel');
    }
  }

  for (final testCase in vectorList(document, 'cases')) {
    test('${testCase['name']}: ${testCase['note']}', () async {
      final ops = vectorList(testCase, 'ops');
      await runOrder(testCase, ops, '');
      if (testCase['permute'] == true) {
        var index = 0;
        for (final order in permutations(ops)) {
          await runOrder(testCase, order, ' (permutation ${index++})');
        }
      }
    });
  }
}
