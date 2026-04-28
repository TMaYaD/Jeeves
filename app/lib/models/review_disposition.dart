/// Per-task disposition choices during focus session review.
enum ReviewDisposition {
  rollover,
  leave,
  maybe;

  /// The string value written to [focus_session_tasks.disposition].
  String get dbValue => name;
}
