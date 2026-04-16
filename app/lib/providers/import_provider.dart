import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/import_service.dart';
import 'inbox_provider.dart';
import 'tags_provider.dart';

export '../services/import_service.dart' show ImportResult;

class ImportState {
  const ImportState({
    this.isLoading = false,
    this.result,
    this.error,
  });

  final bool isLoading;
  final ImportResult? result;
  final String? error;

  ImportState copyWith({
    bool? isLoading,
    ImportResult? result,
    String? error,
  }) =>
      ImportState(
        isLoading: isLoading ?? this.isLoading,
        result: result ?? this.result,
        error: error ?? this.error,
      );
}

class ImportNotifier extends Notifier<ImportState> {
  @override
  ImportState build() => const ImportState();

  Future<void> importFile(File file, String format) async {
    state = const ImportState(isLoading: true);
    try {
      final result = await ref.read(importServiceProvider).importNirvana(
            file: file,
            format: format,
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
