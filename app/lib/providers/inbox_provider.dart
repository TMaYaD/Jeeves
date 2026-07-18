import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'tag_filter_provider.dart';

export 'user_constants.dart' show kLocalUserId;

/// Stream of the Inbox — Captures with `clarified_at IS NULL` (ADR-0006),
/// newest first.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider], matched against each Capture's *tag hints* (AND
/// semantics when multiple tags are selected). Tag hints are not Organising:
/// they only narrow what the user is looking at while clearing the Inbox.
final inboxItemsProvider = StreamProvider<List<Capture>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.captureDao.watchInbox(tagIds: tagIds);
});

/// Notifier exposing inbox mutation operations.
final inboxNotifierProvider = Provider<InboxNotifier>((ref) {
  return InboxNotifier(ref);
});

class InboxNotifier {
  InboxNotifier(this._ref);

  final Ref _ref;

  /// Quick-add: records a raw [title] as a new Capture, unclarified.
  ///
  /// Captures — not Outcomes — are what quick-add produces (ADR-0006): the
  /// user is offloading something that has their attention, and what it should
  /// become is exactly the question clarification answers later. `clarified_at`
  /// is left NULL so the row lands in the Inbox.
  Future<void> addCapture(String title, {String? notes}) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Title cannot be empty');
    }
    final db = _ref.read(databaseProvider);
    final now = DateTime.now();
    final userId = _ref.read(currentUserIdProvider);
    await db.captureDao.insertCapture(CapturesCompanion(
      title: Value(normalizedTitle),
      notes: Value(notes),
      captureSource: const Value('manual'),
      userId: Value(userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
  }
}
