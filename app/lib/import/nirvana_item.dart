/// Format-agnostic intermediate representation of a single Nirvana row.
library;

class NirvanaItem {
  const NirvanaItem({
    required this.id,
    required this.name,
    required this.type,
    required this.state,
    required this.intent,
    required this.doneAt,
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

  /// Normalised GTD state from the Nirvana export: 'inbox' | 'next_action' | 'waiting_for'.
  /// The importer remaps 'waiting_for' to 'next_action' before writing to the DB;
  /// the waiting_for text column is the source of truth for the Waiting For list.
  final String state;

  /// Orthogonal intent: 'next' | 'maybe' | 'trash'
  final String intent;

  /// Non-null when the item was completed in Nirvana; stored as done_at.
  final DateTime? doneAt;
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
