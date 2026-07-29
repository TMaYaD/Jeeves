/// The parts of the converge-verify runner that hold without a PowerSync engine.
///
/// Cutover tooling — removed by #556.
///
/// The runner's reads need a real store and are exercised through
/// `converge_differ_test.dart`'s injected row source; what is pinned here is the
/// request it builds, because an id is opaque data out of the legacy store and a
/// corrupted request would return other rows the screen then reads as divergence.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/cutover/converge_verify/converge_verify_runner.dart';

void main() {
  test('every id round-trips through the detail request verbatim', () {
    const ids = [' a,b&c d ', 'plain-id', 'has#hash', '100%', 'plus+sign'];
    final request = convergeVerifyRowsRequest('todos', ids);

    final parsed = Uri.parse(request);
    expect(parsed.path, convergeVerifyRowsPath);
    expect(parsed.queryParameters['table'], 'todos');
    // Repeated parameters, so a comma inside an id stays inside that id.
    expect(parsed.queryParametersAll['ids'], ids);
  });

  test('an empty id list still names the table', () {
    final parsed = Uri.parse(convergeVerifyRowsRequest('tags', const []));
    expect(parsed.queryParameters['table'], 'tags');
    expect(parsed.queryParametersAll['ids'], isNull);
  });

  test('a server detail failure is a distinct state from an absent row', () {
    const failed = RowComparison(
      id: 'tag-1',
      localCanonical: '["local"]',
      serverCanonical: null,
      serverDetailUnavailable: true,
    );
    const absent = RowComparison(
      id: 'tag-1',
      localCanonical: '["local"]',
      serverCanonical: null,
    );

    expect(failed.serverDetailUnavailable, isTrue);
    expect(absent.serverDetailUnavailable, isFalse);
    // Neither may produce column differences: there is nothing to compare.
    expect(failed.differencesFor('tags'), isEmpty);
    expect(absent.differencesFor('tags'), isEmpty);
  });
}
