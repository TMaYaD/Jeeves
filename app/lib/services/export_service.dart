import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../import/jeeves_export.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';

/// Builds a Jeeves-native data export of the current user's GTD data.
///
/// The counterpart of [ImportService]: it reads the same current user and domain
/// store, and delegates the format to `import/jeeves_export.dart` so export and
/// import share one definition. It produces bytes only — where they go (a save
/// dialog, a share sheet) is the caller's concern.
class ExportService {
  ExportService(this._ref);

  final Ref _ref;

  /// The export document as a JSON string, ready to write to a file.
  Future<String> buildJson() async {
    final userId = _ref.read(currentUserIdProvider);
    final db = _ref.read(databaseProvider);
    final document = await buildJeevesExport(db: db, userId: userId);
    return encodeJeevesExportJson(document);
  }
}

final exportServiceProvider = Provider<ExportService>((ref) {
  return ExportService(ref);
});
