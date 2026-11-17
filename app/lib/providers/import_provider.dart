import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../import/import_progress.dart';
import '../services/import_service.dart';
import 'inbox_provider.dart';
import 'tags_provider.dart';

export '../services/import_service.dart' show ImportFailure, ImportResult;

class ImportState {
  const ImportState({
    this.isLoading = false,
    this.result,
    this.error,
    this.progress,
  });

  final bool isLoading;
  final ImportResult? result;
  final String? error;

  /// How far the running import has got. Null until the import reports its
  /// first batch — an import that has not reported yet is one whose length
  /// is still unknown.
  final ImportProgress? progress;

  ImportState copyWith({
    bool? isLoading,
    ImportResult? result,
    bool clearResult = false,
    String? error,
    bool clearError = false,
    ImportProgress? progress,
    bool clearProgress = false,
  }) =>
      ImportState(
        isLoading: isLoading ?? this.isLoading,
        result: clearResult ? null : (result ?? this.result),
        error: clearError ? null : (error ?? this.error),
        progress: clearProgress ? null : (progress ?? this.progress),
      );
}

class ImportNotifier extends Notifier<ImportState> {
  @override
  ImportState build() => const ImportState();

  Future<void> importFile(Uint8List bytes, String filename, String format) async {
    state = const ImportState(isLoading: true);
    try {
      final result = await ref.read(importServiceProvider).importNirvana(
            bytes: bytes,
            filename: filename,
            format: format,
            // The import reports once per batch. A large file takes minutes,
            // and the user is owed a number that moves.
            onProgress: (progress) {
              state = state.copyWith(progress: progress);
            },
          );
      state = ImportState(result: result);

      // Invalidate list providers so UI reflects imported data
      ref.invalidate(inboxItemsProvider);
      ref.invalidate(projectTagsProvider);
      ref.invalidate(contextTagsProvider);
    } catch (e) {
      state = ImportState(error: e.toString());
    }
  }

  void reset() => state = const ImportState();
}

final importNotifierProvider = NotifierProvider<ImportNotifier, ImportState>(
  ImportNotifier.new,
);
