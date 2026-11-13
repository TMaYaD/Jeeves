/// Orthogonal intent enum — independent of GTD state.
///
/// next: normal actionable item; maybe: deferred for later consideration;
/// trash: discarded — surfaces on the Trash screen, restorable to next or
/// maybe from task detail; the row is never physically deleted.
enum Intent {
  next,
  maybe,
  trash;

  String get value => switch (this) {
        Intent.next => 'next',
        Intent.maybe => 'maybe',
        Intent.trash => 'trash',
      };

  static Intent fromString(String value) => switch (value) {
        'maybe' => Intent.maybe,
        'trash' => Intent.trash,
        _ => Intent.next,
      };
}
