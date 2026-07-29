/// The canonical row serialiser against `spec/converge_verify/`.
///
/// Cutover tooling — removed by #556.
///
/// The twin of `backend/tests/test_converge_verify_canonical.py`: both suites run
/// every vector in the same frozen file, which is the only thing keeping the two
/// implementations from drifting. Neither suite regenerates it — see the spec's
/// README.
///
/// This file also holds the Dart half of the anti-drift guard: the manifest must
/// match the live [powersyncSchema], so a newly synced column fails the suite
/// instead of going quietly unverified.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' as ps;

import 'package:jeeves/cutover/converge_verify/canonical_row.dart';
import 'package:jeeves/database/powersync_schema.g.dart';

/// `flutter test` runs with `app/` as the working directory (docs/TESTING.md).
const String _specFile =
    '../spec/converge_verify/canonical_row_vectors.json';

Map<String, dynamic>? _cached;

Map<String, dynamic> spec() {
  final loaded = _cached;
  if (loaded != null) return loaded;
  final file = File(_specFile);
  if (!file.existsSync()) {
    throw StateError(
      'Converge-verify vectors not found at ${file.absolute.path}. Run '
      '`flutter test` from the app/ directory so the repo-root spec/ is '
      'reachable.',
    );
  }
  return _cached =
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<Map<String, dynamic>> _vectorList(Object? raw) =>
    [for (final entry in raw! as List<dynamic>) entry as Map<String, dynamic>];

List<Map<String, dynamic>> rowVectors() => _vectorList(spec()['row_vectors']);

List<Map<String, dynamic>> timestampVectors() => _vectorList(
      (spec()['timestamp_parsing'] as Map<String, dynamic>)['vectors'],
    );

void main() {
  group('the manifest is the contract', () {
    test('matches the frozen spec', () {
      final specManifest = <String, List<(String, String)>>{
        for (final entry in (spec()['manifest'] as Map<String, dynamic>).entries)
          entry.key: [
            for (final pair in entry.value as List<dynamic>)
              (
                (pair as List<dynamic>)[0] as String,
                pair[1] as String,
              ),
          ],
      };
      expect(canonicalRowManifest, specManifest);
    });

    test('declared exclusions match the frozen spec', () {
      final expected = <String, List<String>>{
        for (final entry
            in (spec()['excluded_columns'] as Map<String, dynamic>).entries)
          entry.key: [
            for (final column in entry.value as List<dynamic>) column as String,
          ],
      };
      expect(excludedColumnsReport(), expected);
    });

    test('matches the live PowerSync schema', () {
      // A newly synced table or column fails here rather than going unverified.
      // The reverse direction matters just as much: a manifest column the schema
      // does not have would canonicalise to a missing_column sentinel on every
      // row, reporting the whole table as divergent for a reason that is not the
      // store's fault.
      final schemaByName = <String, ps.Table>{
        for (final table in powersyncSchema.tables) table.name: table,
      };
      expect(schemaByName.keys.toSet(), canonicalRowManifest.keys.toSet());

      for (final entry in canonicalRowManifest.entries) {
        final table = schemaByName[entry.key]!;
        // PowerSync auto-injects `id`, so it is absent from the declared columns
        // but present on every row the view yields.
        final schemaColumns = {'id', for (final c in table.columns) c.name};
        final excluded = {
          ...excludedColumnsEveryTable,
          ...?excludedColumnsByTable[entry.key],
        };
        expect(
          excluded.difference(schemaColumns),
          isEmpty,
          reason: '${entry.key}: an exclusion names a column the schema lacks',
        );
        expect(
          {for (final (column, _) in entry.value) column},
          schemaColumns.difference(excluded),
          reason: entry.key,
        );
      }
    });

    test('columns are alphabetical and unique', () {
      for (final entry in canonicalRowManifest.entries) {
        final names = [for (final (column, _) in entry.value) column];
        expect(names, orderedEquals([...names]..sort()), reason: entry.key);
        expect(names.toSet().length, names.length, reason: entry.key);
      }
    });

    test('every kind is declared in the spec', () {
      final declared = {
        for (final kind in spec()['column_kinds'] as List<dynamic>)
          kind as String,
      };
      for (final entry in canonicalRowManifest.entries) {
        for (final (column, kind) in entry.value) {
          expect(declared, contains(kind), reason: '${entry.key}.$column');
        }
      }
    });

    test('convergeVerifyTables covers the manifest', () {
      expect(convergeVerifyTables.toSet(), canonicalRowManifest.keys.toSet());
      expect(convergeVerifyTables.length, canonicalRowManifest.length);
    });

    test('the spec version matches', () {
      expect(spec()['spec_version'], convergeVerifySpecVersion);
    });
  });

  group('timestamp parsing rules', () {
    test('the pattern is the frozen grammar, character for character', () {
      // Both sides spell the grammar out in the spec so neither can quietly
      // loosen it — a widened parser is how a real divergence gets normalised
      // away into a false "converged".
      final grammar =
          (spec()['timestamp_parsing'] as Map<String, dynamic>)['grammar'];
      expect(timestampPattern.pattern, grammar);
    });

    for (final vector in timestampVectors()) {
      test(vector['name'] as String, () {
        expect(parseTimestampUtcMs(vector['raw']), vector['expected']);
      });
    }

    test('the spec carries both accepting and refusing vectors', () {
      final expectations = [
        for (final vector in timestampVectors()) vector['expected'],
      ];
      expect(expectations.any((value) => value == null), isTrue);
      expect(expectations.any((value) => value != null), isTrue);
    });

    test('a DateTime and its equivalent text agree', () {
      final moment = DateTime.utc(2026, 4, 29, 18, 30);
      expect(parseTimestampUtcMs(moment), '2026-04-29T18:30:00.000Z');
      expect(
        parseTimestampUtcMs(moment),
        parseTimestampUtcMs('2026-04-30T00:00:00.000 +05:30'),
      );
    });

    test('a local DateTime converts rather than being read off the wall clock',
        () {
      final local = DateTime(2026, 4, 29, 18, 30);
      expect(parseTimestampUtcMs(local), parseTimestampUtcMs(local.toUtc()));
    });

    test('microseconds truncate rather than round', () {
      final moment = DateTime.utc(2026, 4, 30, 5, 30, 0, 123, 999);
      expect(parseTimestampUtcMs(moment), '2026-04-30T05:30:00.123Z');
    });

    test('non-timestamp types are refused rather than guessed', () {
      // Epoch milliseconds are a plausible legacy shape and deliberately not
      // inferred: guessing seconds-vs-millis would invent convergence.
      expect(parseTimestampUtcMs(1714435200000), isNull);
      expect(parseTimestampUtcMs(true), isNull);
      expect(parseTimestampUtcMs(null), isNull);
    });
  });

  group('row vectors', () {
    for (final vector in rowVectors()) {
      test(vector['name'] as String, () {
        final raw = (vector['raw'] as Map<String, dynamic>)
            .map<String, Object?>((key, value) => MapEntry(key, value));
        final result = canonicalRow(vector['table'] as String, raw);
        expect(result.canonical, vector['canonical']);
        expect(result.digest, vector['digest']);
        expect(
          [for (final anomaly in result.anomalies) anomaly.toJson()],
          vector['anomalies'],
        );
      });

      test('${vector['name']}: pinned digest is sha256 of pinned canonical', () {
        // The only computed field in the spec, re-derived rather than trusted.
        final expected = sha256
            .convert(utf8.encode(vector['canonical'] as String))
            .toString();
        expect(vector['digest'], expected);
      });
    }

    test('every table has at least one row vector', () {
      expect(
        {for (final vector in rowVectors()) vector['table'] as String},
        canonicalRowManifest.keys.toSet(),
      );
    });

    test('the two stores\' shapes agree on a digest', () {
      // The point of the whole exercise: one logical row, two raw shapes, one
      // digest. The local store holds Drift's space-before-offset text and
      // SQLite integer booleans; Postgres holds timestamptz and real booleans.
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final vector in rowVectors()) {
        final group = vector['logical_row_group'] as String?;
        if (group != null) groups.putIfAbsent(group, () => []).add(vector);
      }
      expect(groups, isNotEmpty, reason: 'the spec declares no cross-shape group');
      groups.forEach((group, members) {
        expect(members.length, greaterThan(1),
            reason: '$group has one member, so it proves nothing');
        final digests = {
          for (final member in members)
            canonicalRow(
              member['table'] as String,
              (member['raw'] as Map<String, dynamic>)
                  .map<String, Object?>((k, v) => MapEntry(k, v)),
            ).digest,
        };
        expect(digests.length, 1, reason: group);
      });
    });

    test('excluded columns do not reach the digest', () {
      final base = (rowVectors().first['raw'] as Map<String, dynamic>)
          .map<String, Object?>((k, v) => MapEntry(k, v));
      final other = {
        ...base,
        'user_id': 'someone-else',
        'time_spent_minutes': 4321,
      };
      expect(canonicalRow('todos', base).digest,
          canonicalRow('todos', other).digest);
    });

    test('null is not the empty string', () {
      final base = <String, Object?>{
        for (final (column, _) in canonicalRowManifest['tags']!) column: null,
      };
      final withEmpty = {...base, 'color': ''};
      expect(canonicalRow('tags', base).canonical, '[null,null,null,null]');
      expect(canonicalRow('tags', withEmpty).canonical, '["",null,null,null]');
      expect(canonicalRow('tags', base).digest,
          isNot(canonicalRow('tags', withEmpty).digest));
    });
  });

  group('the encoder\'s escape table', () {
    test('control characters use lowercase hex', () {
      // Uppercase hex is what dart:convert's own encoder emits for a control
      // with no short escape, which is the whole reason this one is hand-rolled.
      expect(encodeCanonicalText(String.fromCharCode(0x0b)), r'"\u000b"');
      expect(encodeCanonicalText(String.fromCharCode(0x1f)), r'"\u001f"');
    });

    test('short escapes win over the hex form', () {
      expect(encodeCanonicalText('\b\t\n\f\r'), r'"\b\t\n\f\r"');
    });

    test('delete and non-ASCII are emitted literally', () {
      final del = String.fromCharCode(0x7f);
      expect(encodeCanonicalText('${del}café 🚀'),
          '"${del}café 🚀"');
    });

    test('quote and backslash are escaped', () {
      expect(encodeCanonicalText('a"b\\c'), r'"a\"b\\c"');
    });

    test('a surrogate pair survives code-unit iteration', () {
      expect(encodeCanonicalText('🚀'), '"🚀"');
      expect(jsonDecode(encodeCanonicalText('🚀')), '🚀');
    });

    test('every canonical string in the spec is parseable JSON', () {
      for (final vector in rowVectors()) {
        expect(
          () => jsonDecode(vector['canonical'] as String),
          returnsNormally,
          reason: vector['name'] as String,
        );
      }
    });
  });

  group('convergeMapDigest', () {
    test('is insertion-order independent', () {
      const a = {'x': 'd1', 'y': 'd2'};
      const b = {'y': 'd2', 'x': 'd1'};
      expect(convergeMapDigest(a), convergeMapDigest(b));
    });

    test('changes when any digest changes', () {
      expect(
        convergeMapDigest(const {'x': 'd1'}),
        isNot(convergeMapDigest(const {'x': 'd2'})),
      );
      expect(
        convergeMapDigest(const {'x': 'd1'}),
        isNot(convergeMapDigest(const {'x': 'd1', 'y': 'd1'})),
      );
    });
  });
}
