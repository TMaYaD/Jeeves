/// The import boundary the sync host design rests on.
///
/// Source scans, not behaviour: they fail the build the day someone wires a
/// domain surface to the host, or the host to the op log.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files that belong to the op-log client: its wire, its identity, its transport.
const Set<String> _opLogFiles = {
  'sync_client.dart',
  'reducer.dart',
  'envelope.dart',
  'op_payload.dart',
  'enrolment.dart',
  'sync_stack.dart',
  'sync_lifecycle.dart',
  'http_sync_transport.dart',
  'sync_transport.dart',
  'initial_upload.dart',
  'compaction.dart',
};

List<File> _dartFiles(String directory) => [
      for (final entity in Directory(directory).listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart')) entity,
    ];

Iterable<String> _imports(File file) => RegExp(r'''^(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true)
    .allMatches(file.readAsStringSync())
    .map((match) => match.group(1)!);

void main() {
  test('nothing under sync/host imports an op-log file', () {
    final offenders = <String>[];
    for (final file in _dartFiles('lib/sync/host')) {
      for (final import in _imports(file)) {
        if (_opLogFiles.contains(import.split('/').last)) {
          offenders.add('${file.path} imports $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('nothing outside lib/sync and lib/providers imports the host', () {
    final offenders = <String>[];
    for (final file in _dartFiles('lib')) {
      final path = file.path;
      if (path.startsWith('lib/sync/') || path.startsWith('lib/providers/')) continue;
      if (path == 'lib/main.dart') continue;
      for (final import in _imports(file)) {
        if (import.contains('sync/host/') || import.contains('sync_host')) {
          offenders.add('$path imports $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('nothing under sync/vault imports the merge core, the strategy registry '
      'or an op-log file', () {
    // The vault is a carrier: it turns a page into changes and writes the
    // host's merged state back. It never settles a value itself, so the merge
    // core and the strategy registry are out of its reach — as is the op log,
    // which the host does not sit on.
    final offenders = <String>[];
    for (final file in _dartFiles('lib/sync/vault')) {
      for (final import in _imports(file)) {
        final name = import.split('/').last;
        if (name == 'merge_core.dart' ||
            name == 'merge_strategy.dart' ||
            _opLogFiles.contains(name)) {
          offenders.add('${file.path} imports $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('nothing outside lib/sync and lib/providers imports the vault', () {
    final offenders = <String>[];
    for (final file in _dartFiles('lib')) {
      final path = file.path;
      if (path.startsWith('lib/sync/') || path.startsWith('lib/providers/')) {
        continue;
      }
      for (final import in _imports(file)) {
        if (import.contains('sync/vault/')) {
          offenders.add('$path imports $import');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
