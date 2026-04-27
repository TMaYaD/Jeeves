/// Format-agnostic intermediate representation of a single Nirvana row.
library;

class NirvanaItem {
  const NirvanaItem({
    required this.id,
    required this.name,
    required this.type,
    required this.state,
    required this.completed,
    required this.notes,
    required this.tags,
    required this.energyLevel,
    required this.timeEstimate,
    required this.dueDate,
    required this.parentId,
    required this.parentName,
    required this.waitingFor,
  });

  final String id;
  final String name;

  /// 'task' or 'project'
  final String type;

  /// Normalised GTD state: 'inbox' | 'next_action' | 'done' | 'waiting_for' |
  /// 'someday_maybe'
  final String state;

  final bool completed;
  final String? notes;
  final List<String> tags;

  /// 'low' | 'medium' | 'high' | null
  final String? energyLevel;

  /// Estimated effort in minutes; null when absent.
  final int? timeEstimate;

  /// ISO-8601 date string ('YYYY-MM-DD') or null.
  final String? dueDate;

  /// UUID reference to a parent project item (JSON format).
  final String? parentId;

  /// Project name reference (CSV format).
  final String? parentName;

  final String? waitingFor;
}
