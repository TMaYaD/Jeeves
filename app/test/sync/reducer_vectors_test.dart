/// The reducer against `spec/sync/reducer_v1_vectors.json`.
///
/// The vectors are shared with the backend so field-grain LWW is pinned
/// identically on both sides of any future server-side tooling; today the Dart
/// reducer is their only consumer, and they are what stops a "harmless"
/// tweak to the merge rules from silently changing what converges.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';

import 'vectors.dart';

void main() {
  final document = reducerVectors();
  final localNowMs = document['local_now_ms'] as int;
  final futureSkewBoundMs = document['future_skew_bound_ms'] as int;

  test('the skew bound in the vectors is the reducer default', () {
    expect(futureSkewBoundMs, defaultFutureSkewBoundMs);
  });

  for (final testCase in vectorList(document, 'cases')) {
    test('${testCase['name']}: ${testCase['note']}', () async {
      final database = SyncDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final registry = CollectionRegistry(database);
      final reducer = Reducer(
        database,
        nowMs: () => localNowMs,
        futureSkewBoundMs: futureSkewBoundMs,
      );

      final quarantined = <String>[];
      for (final op in vectorList(testCase, 'ops')) {
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

      expect(quarantined, testCase['expected_quarantine_reasons']);

      final expectedState =
          testCase['expected_entities'] as Map<String, dynamic>;
      for (final collection in expectedState.keys) {
        final actual = await registry.register(collection).readAll();
        expect(
          actual,
          expectedState[collection],
          reason: 'collection $collection',
        );
      }
    });
  }
}
