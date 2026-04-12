/// AI service — natural language task entry, suggestions, summarization.
///
/// All LLM calls are proxied through the FastAPI backend's /ai/* endpoints.
/// This keeps API keys server-side and allows model swapping without app
/// updates. On-device models are a future option for latency-sensitive paths.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tag.dart';
import 'api_service.dart';

class ParsedTask {
  const ParsedTask({
    required this.title,
    this.dueDate,
    this.listName,
    this.tags = const [],
    this.notes,
    // GTD enrichment fields
    this.projectName,
    this.areaName,
    this.energyLevel,
    this.timeEstimateMinutes,
  });

  final String title;
  final DateTime? dueDate;
  final String? listName;
  final List<String> tags;
  final String? notes;

  /// GTD project name extracted from natural language input.
  final String? projectName;

  /// GTD area of responsibility extracted from natural language input.
  final String? areaName;

  /// Required energy level: low | medium | high.
  final String? energyLevel;

  /// Estimated effort in minutes.
  final int? timeEstimateMinutes;
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
      projectName: result['project_name'] as String?,
      areaName: result['area_name'] as String?,
      energyLevel: result['energy_level'] as String?,
      timeEstimateMinutes: result['time_estimate_minutes'] as int?,
    );
  }

  /// Resolve GTD project and area names from a [ParsedTask] into [Tag] objects
  /// suitable for upserting into the local database before creating the todo.
  ///
  /// Returns a list of tags with types assigned:
  /// - [projectName] → TagType.project
  /// - [areaName]    → TagType.area
  /// - plain [tags]  → type inferred by naming convention (@ → context, else label)
  List<Tag> resolveGtdTags(ParsedTask task, {required String userId}) {
    final resolved = <Tag>[];

    if (task.projectName != null) {
      resolved.add(Tag(
        id: _deterministicId(userId, task.projectName!, TagType.project.name),
        name: task.projectName!,
        type: TagType.project.name,
        userId: userId,
      ));
    }

    if (task.areaName != null) {
      resolved.add(Tag(
        id: _deterministicId(userId, task.areaName!, TagType.area.name),
        name: task.areaName!,
        type: TagType.area.name,
        userId: userId,
      ));
    }

    for (final tagName in task.tags) {
      final type = tagName.startsWith('@') ? TagType.context.name : TagType.label.name;
      resolved.add(Tag(
        id: _deterministicId(userId, tagName, type),
        name: tagName,
        type: type,
        userId: userId,
      ));
    }

    return resolved;
  }

  /// Deterministic placeholder ID — in practice the real ID comes from the
  /// database upsert (by name + userId). This is only used for local staging
  /// before the record is committed to Drift.
  String _deterministicId(String userId, String name, String type) =>
      '$userId:$type:$name';

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
