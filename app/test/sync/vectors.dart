/// Loader for the frozen golden vectors in `spec/sync/`.
///
/// `backend/tests/sync/vectors.py` loads the same two files. Neither suite
/// regenerates them: a codec change that is not a deliberate protocol change
/// must fail rather than move the goalposts.
library;

import 'dart:convert';
import 'dart:io';

/// `flutter test` runs with `app/` as the working directory.
const String _specSyncDirectory = '../spec/sync';

Map<String, dynamic> _load(String filename) {
  final file = File('$_specSyncDirectory/$filename');
  if (!file.existsSync()) {
    throw StateError(
      'Golden vectors not found at ${file.absolute.path}. Run `flutter test` '
      'from the app/ directory so the repo-root spec/ is reachable.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic>? _envelopeVectors;
Map<String, dynamic>? _reducerVectors;

Map<String, dynamic> envelopeVectors() =>
    _envelopeVectors ??= _load('envelope_v1_vectors.json');

Map<String, dynamic> reducerVectors() =>
    _reducerVectors ??= _load('reducer_v1_vectors.json');

List<Map<String, dynamic>> vectorList(Map<String, dynamic> document, String key) =>
    [for (final entry in document[key] as List<dynamic>) entry as Map<String, dynamic>];

/// Byte offset of [fieldName] within the 158-byte header, read off the frozen
/// `header_field_layout`.
///
/// Every offset is published there and asserted contiguous, so a test that pokes
/// header bytes reads the layout rather than hand-copying a literal that will not
/// move when a field width does.
int headerFieldOffset(String fieldName) {
  for (final field in vectorList(
    envelopeVectors()['protocol'] as Map<String, dynamic>,
    'header_field_layout',
  )) {
    if (field['name'] == fieldName) return field['offset'] as int;
  }
  throw StateError('no header field named $fieldName in header_field_layout');
}
