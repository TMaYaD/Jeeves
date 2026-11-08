import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the set of context tag IDs currently active as a sticky nav filter.
///
/// Tapping a tag chip in the drawer calls [TagFilterNotifier.toggle]; clearing
/// the strip calls [TagFilterNotifier.clear].  Every GTD list provider watches
/// this and re-subscribes its DAO stream whenever the set changes.
final tagFilterProvider = NotifierProvider<TagFilterNotifier, Set<String>>(
  TagFilterNotifier.new,
);

class TagFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String tagId) {
    final current = state;
    if (current.contains(tagId)) {
      state = current.where((id) => id != tagId).toSet();
    } else {
      state = {...current, tagId};
    }
  }

  /// Replaces the whole filter with just [tagId] — a Projects-section tap is
  /// "show me this project", not "also narrow by this project".
  void selectOnly(String tagId) => state = {tagId};

  void clear() => state = const {};
}
