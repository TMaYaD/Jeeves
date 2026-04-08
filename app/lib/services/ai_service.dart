/// AI service — natural language task entry, suggestions, summarization.
///
/// All LLM calls are proxied through the FastAPI backend's /ai/* endpoints.
/// This keeps API keys server-side and allows model swapping without app
/// updates. On-device models are a future option for latency-sensitive paths.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_service.dart';

class ParsedTask {
  const ParsedTask({
    required this.title,
    this.dueDate,
    this.listName,
    this.tags = const [],
    this.notes,
  });

  final String title;
  final DateTime? dueDate;
  final String? listName;
  final List<String> tags;
  final String? notes;
}

class AiService {
  AiService({required ApiService apiService}) : _api = apiService;

  final ApiService _api;

  /// Parse a natural language string into a structured [ParsedTask].
  Future<ParsedTask> parseNaturalLanguage(String input) async {
    final result = await _api.post('/ai/parse', {'input': input});
    return ParsedTask(
      title: result['title'] as String,
      dueDate: result['due_date'] != null
          ? DateTime.parse(result['due_date'] as String)
          : null,
      listName: result['list_name'] as String?,
      tags: (result['tags'] as List<dynamic>?)
              ?.map((t) => t as String)
              .toList() ??
          [],
      notes: result['notes'] as String?,
    );
  }

  /// Get AI suggestions for a todo (related tasks, next actions, etc.).
  Future<List<String>> getSuggestions(String todoId) async {
    final result = await _api.get('/ai/suggestions/$todoId');
    return (result['suggestions'] as List<dynamic>)
        .map((s) => s as String)
        .toList();
  }

  /// Summarize a list of todos into a short natural language summary.
  Future<String> summarizeList(String listId) async {
    final result = await _api.get('/ai/summarize/$listId');
    return result['summary'] as String;
  }
}

final aiServiceProvider = Provider<AiService>((ref) {
  final api = ref.watch(apiServiceProvider);
  return AiService(apiService: api);
});
