import '../database/gtd_database.dart' show Capture, Tag, Todo;

/// Which field(s) of a task matched the search query.
enum SearchMatchField { title, notes, projectTag, contextTag, areaTag }

/// A search hit: the matching row, its tags, and metadata about what matched.
///
/// Since the Capture/Outcome split (ADR-0006) a hit is one of two things, and
/// exactly one of [todo] / [capture] is non-null:
///
/// - an **Outcome** ([todo]) — something already clarified, tagged via
///   `todo_tags`;
/// - a **Capture** ([capture]) — something still in the Inbox, tagged via its
///   `capture_tags` *hints*.
///
/// Both are searchable so an unclarified thought stays findable: without the
/// Capture leg, everything the user had typed but not yet clarified would
/// silently drop out of search the moment the Inbox stopped living in `todos`.
class SearchResult {
  const SearchResult({
    this.todo,
    this.capture,
    required this.tags,
    required this.matchedFields,
    this.matchSnippet,
  }) : assert(
          (todo == null) != (capture == null),
          'A hit is either an Outcome or a Capture, never both or neither',
        );

  /// The matching Outcome, or null when this hit is a Capture.
  final Todo? todo;

  /// The matching Inbox Capture, or null when this hit is an Outcome.
  final Capture? capture;

  final List<Tag> tags;

  /// Fields that contained the search term.
  final Set<SearchMatchField> matchedFields;

  /// Short excerpt from notes around the hit position (≤ 120 chars).
  final String? matchSnippet;

  /// True when the hit is a Capture still awaiting clarification.
  bool get isCapture => capture != null;

  /// Row id — an Outcome id or a Capture id.
  String get id => todo?.id ?? capture!.id;

  /// Title of whichever row matched.
  String get title => todo?.title ?? capture!.title;

  /// Notes of whichever row matched.
  String? get notes => todo?.notes ?? capture!.notes;
}
