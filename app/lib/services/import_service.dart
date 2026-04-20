import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_service.dart';

class ImportResult {
  const ImportResult({
    required this.importedCount,
    required this.skippedCount,
    required this.projectTagsCreated,
  });

  factory ImportResult.fromJson(Map<String, dynamic> json) => ImportResult(
        importedCount: (json['imported_count'] as num).toInt(),
        skippedCount: (json['skipped_count'] as num).toInt(),
        projectTagsCreated: (json['project_tags_created'] as num).toInt(),
      );

  final int importedCount;
  final int skippedCount;
  final int projectTagsCreated;
}

class ImportService {
  ImportService(this._api);

  final ApiService _api;

  Future<ImportResult> importNirvana({
    required Uint8List bytes,
    required String filename,
    String format = 'auto',
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
      'format': format,
    });

    final json = await _api.postFormData('/import/nirvana', formData);
    return ImportResult.fromJson(json);
  }
}

final importServiceProvider = Provider<ImportService>((ref) {
  return ImportService(ref.read(apiServiceProvider));
});
