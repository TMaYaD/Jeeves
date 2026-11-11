/// One-time conversion of time-named context tags into TimeContexts (issue #238).
///
/// Before TimeContext existed, "@morning" or "@weekend" were ordinary context
/// tags on an Outcome. Now the Action carries the predicate: each such tag, on
/// every Outcome that has a current Action without a TimeContext, becomes the
/// mapped TimeContext and the Outcome↔tag link is removed. The Tag row is never
/// deleted; Outcomes without a current Action keep their link; names outside the
/// vocabulary are untouched.
///
/// Runs as an ordinary captured write (not in `onUpgrade`, which authors no
/// ops), so an enrolled device's other devices receive it.
library;

import 'package:drift/drift.dart';

import '../models/time_context.dart';
import 'gtd_database.dart';

TimeContext _window(Set<int> days, [int? start, int? end]) =>
    TimeContext.create(days: days, startMinute: start, endMinute: end)!;

final Set<int> _everyDay = {1, 2, 3, 4, 5, 6, 7};
final TimeContext _officeHours = _window({1, 2, 3, 4, 5}, 9 * 60, 17 * 60);

/// Normalised tag name (see [normaliseContextTagName]) → TimeContext.
final Map<String, TimeContext> timeNamedContextTags = {
  'morning': _window(_everyDay, 6 * 60, 12 * 60),
  'afternoon': _window(_everyDay, 12 * 60, 17 * 60),
  'evening': _window(_everyDay, 17 * 60, 22 * 60),
  'weekday': _window({1, 2, 3, 4, 5}),
  'weekdays': _window({1, 2, 3, 4, 5}),
  'weekend': _window({6, 7}),
  'weekends': _window({6, 7}),
  'work hours': _officeHours,
  'workhours': _officeHours,
  'office hours': _officeHours,
  'business hours': _officeHours,
};

/// Lowercase, trim, strip a leading `@`, collapse runs of space, `-` and `_`.
String normaliseContextTagName(String name) => name
    .toLowerCase()
    .trim()
    .replaceFirst(RegExp(r'^@'), '')
    .replaceAll(RegExp(r'[\s_\-]+'), ' ')
    .trim();

/// Converts in one [GtdDatabase.capturing] transaction (all or nothing).
/// Returns the number of Outcome↔tag links converted.
Future<int> convertTimeNamedContextTags(
  GtdDatabase db, {
  DateTime? now,
}) async {
  final ts = (now ?? DateTime.now()).toUtc();
  final converted = await db.capturing(() async {
    final contextTags = await (db.select(db.tags)
          ..where((t) => t.type.equals('context'))
          ..orderBy([(t) => OrderingTerm.asc(t.name), (t) => OrderingTerm.asc(t.id)]))
        .get();
    var linkCount = 0;
    for (final tag in contextTags) {
      final value = timeNamedContextTags[normaliseContextTagName(tag.name)];
      if (value == null) continue;
      final links = await (db.select(db.todoTags)
            ..where((l) => l.tagId.equals(tag.id))
            ..orderBy([(l) => OrderingTerm.asc(l.todoId)]))
          .get();
      for (final link in links) {
        final action = await db.actionDao.getCurrentAction(link.todoId);
        if (action == null || action.timeContext != null) continue;
        await db.actionDao.applySetTimeContext(action.id, value, ts: ts);
        await db.tagDao.unassignTag(link.todoId, tag.id);
        linkCount++;
      }
    }
    return linkCount;
  });
  if (converted > 0) {
    db.notifyActionsViewWrite();
    db.notifyTodosViewWrite(includeTodoTags: true);
  }
  return converted;
}
