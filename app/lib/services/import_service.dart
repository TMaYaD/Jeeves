import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../import/nirvana_local_import.dart' as local;
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';

export '../import/nirvana_local_import.dart' show ImportResult;

class ImportService {
  ImportService(this._ref);

  final Ref _ref;

  Future<local.ImportResult> importNirvana({
    required Uint8List bytes,
    required String filename,
    String format = 'auto',
  }) {
    final userId = _ref.read(currentUserIdProvider);
    final db = _ref.read(databaseProvider);
    return local.importNirvanaLocally(
      bytes: bytes,
      filename: filename,
      format: format,
      userId: userId,
      db: db,
    );
  }
}

final importServiceProvider = Provider<ImportService>((ref) {
  return ImportService(ref);
});
