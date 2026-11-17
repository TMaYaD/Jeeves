import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../import/import_progress.dart';
import '../import/nirvana_local_import.dart' as local;
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';

export '../import/nirvana_local_import.dart' show ImportFailure, ImportResult;

class ImportService {
  ImportService(this._ref);

  final Ref _ref;

  /// Import [bytes] into the local store, reporting progress as it goes.
  ///
  /// [onProgress] is optional, and is called with the number of records
  /// finished and the number the file carried. It is called on the caller's
  /// own isolate, so a listener that touches widgets must be safe to call
  /// often — the import reports once per batch, not once per record.
  Future<local.ImportResult> importNirvana({
    required Uint8List bytes,
    required String filename,
    String format = 'auto',
    ImportProgressCallback? onProgress,
  }) {
    final userId = _ref.read(currentUserIdProvider);
    final db = _ref.read(databaseProvider);
    return local.importNirvanaLocally(
      bytes: bytes,
      filename: filename,
      format: format,
      userId: userId,
      db: db,
      onProgress: onProgress,
    );
  }
}

final importServiceProvider = Provider<ImportService>((ref) {
  return ImportService(ref);
});
