/// DAO for the named time windows (issue #239).
///
/// A time window is a set of hours — one entry per day of the week, days with
/// no hours simply absent — stored as canonical JSON (see
/// `models/time_window_hours.dart`), so two devices that build the same hours
/// write the same bytes.
///
/// Every write runs inside [GtdDatabase.capturing] and describes its effect to
/// the op log, so a window made on one device reaches the others.
///
/// **There is no SQL foreign key from `actions.time_window_id` to
/// `time_windows.id`** — the log has none, and a reference to a window that no
/// longer exists has to stay representable (a dangling reference reads as "no
/// window"). So the delete path detaches by hand: every Action that points at
/// the window gets `time_window_id = null` and an op saying so, and only then
/// does the row go — with a tombstone.
library;

import 'package:drift/drift.dart';

import '../../models/time_window_hours.dart';
import '../../sync/collection_codecs.dart';
import '../../utils/uuid.dart';
import '../gtd_database.dart';

part 'time_window_dao.g.dart';

/// A named time window with the number of current Actions of active Outcomes
/// that use it (issue #55).
typedef TimeWindowWithCount = ({TimeWindow window, int useCount});

@DriftAccessor(tables: [TimeWindows, Actions, Todos, Places])
class TimeWindowDao extends DatabaseAccessor<GtdDatabase>
    with _$TimeWindowDaoMixin {
  TimeWindowDao(super.db);

  /// The user's named time windows, in name order.
  Stream<List<TimeWindow>> watchTimeWindows() {
    return (select(timeWindows)
          ..orderBy([(w) => OrderingTerm.asc(w.name)]))
        .watch();
  }

  /// Whether the named time window [id] still exists.
  Future<bool> timeWindowExists(String id) async {
    final row = await (select(timeWindows)..where((w) => w.id.equals(id)))
        .getSingleOrNull();
    return row != null;
  }

  /// The user's named time windows with the number of current Actions of
  /// active Outcomes that use each, in name order.
  ///
  /// A window that no Action uses counts zero; an Action whose Outcome is
  /// done or trashed does not count, because the user is not acting on it.
  Stream<List<TimeWindowWithCount>> watchTimeWindowsWithUseCount() {
    final query = select(timeWindows).join([
      leftOuterJoin(
        actions,
        actions.timeWindowId.equalsExp(timeWindows.id) &
            actions.role.equals('current'),
      ),
      leftOuterJoin(
        todos,
        todos.id.equalsExp(actions.outcomeId) &
            todos.doneAt.isNull() &
            todos.intent.equals('trash').not(),
      ),
    ]);
    return query.watch().map((rows) {
      final byId = <String, TimeWindowWithCount>{};
      for (final row in rows) {
        final window = row.readTable(timeWindows);
        final todo = row.readTableOrNull(todos);
        final existing = byId[window.id];
        byId[window.id] = (
          window: window,
          useCount: (existing?.useCount ?? 0) + (todo == null ? 0 : 1),
        );
      }
      final list = byId.values.toList()
        ..sort((a, b) => a.window.name.compareTo(b.window.name));
      return list;
    });
  }

  /// Creates a named time window and returns its id, or null when the write
  /// is refused.
  ///
  /// Refused: a blank name, a name longer than [TimeWindows.maxNameLength],
  /// and hours that do not encode — no days at all, a day outside Monday to
  /// Sunday, a clock outside the day, or a day that starts and ends at the
  /// same minute. A refused write stores nothing and authors no op.
  Future<String?> createTimeWindow({
    required String name,
    required Map<int, DayHours> hours,
    required String userId,
    DateTime? now,
  }) {
    final trimmed = name.trim();
    if (!_isAcceptableName(trimmed)) return Future.value(null);
    final encoded = TimeWindowHours.create(hours)?.encode();
    if (encoded == null) return Future.value(null);
    final ts = (now ?? DateTime.now()).toUtc();
    return attachedDatabase.capturing(() async {
      final id = uuid.v4();
      await into(timeWindows).insert(
        TimeWindowsCompanion(
          id: Value(id),
          userId: Value(userId),
          name: Value(trimmed),
          hours: Value(encoded),
          createdAt: Value(ts),
        ),
      );
      // Creation asserts the full field set, so a peer that has never seen
      // the window can build the whole row.
      attachedDatabase.opCapture.write(
        collection: timeWindowsCollection,
        entityId: id,
        fields: {
          'user_id': userId,
          'name': trimmed,
          'hours': encoded,
          'created_at': encodeInstant(ts),
        },
      );
      return id;
    }).then((id) {
      attachedDatabase.notifyTimeWindowsViewWrite();
      return id;
    });
  }

  /// Updates a named time window: any of its name and its hours.
  ///
  /// Returns whether the row was written. A refused update — a blank or
  /// over-long name, hours that do not encode — writes nothing and authors no
  /// op. So does an update of a window that does not exist, and an update
  /// whose values did not change.
  ///
  /// Only the fields the caller actually named are written and asserted.
  Future<bool> updateTimeWindow({
    required String windowId,
    String? name,
    Map<int, DayHours>? hours,
    DateTime? now,
  }) {
    final trimmedName = name?.trim();
    if (name != null && !_isAcceptableName(trimmedName!)) {
      return Future.value(false);
    }
    final encodedHours = hours == null ? null : TimeWindowHours.create(hours)?.encode();
    if (hours != null && encodedHours == null) return Future.value(false);
    return attachedDatabase.capturing(() async {
      final current =
          await (select(timeWindows)..where((w) => w.id.equals(windowId)))
              .getSingleOrNull();
      if (current == null) return false;

      final ts = (now ?? DateTime.now()).toUtc();
      final newName =
          (trimmedName != null && trimmedName != current.name) ? trimmedName : null;
      final newHours =
          (encodedHours != null && encodedHours != current.hours) ? encodedHours : null;
      if (newName == null && newHours == null) return false;

      final fields = <String, Object?>{};
      if (newName != null) fields['name'] = newName;
      if (newHours != null) fields['hours'] = newHours;
      fields['updated_at'] = encodeInstant(ts);

      await (update(timeWindows)..where((w) => w.id.equals(windowId))).write(
        TimeWindowsCompanion(
          name: newName == null ? const Value.absent() : Value(newName),
          hours: newHours == null ? const Value.absent() : Value(newHours),
          updatedAt: Value(ts),
        ),
      );
      attachedDatabase.opCapture.write(
        collection: timeWindowsCollection,
        entityId: windowId,
        fields: fields,
      );
      return true;
    }).then((written) {
      if (written) attachedDatabase.notifyTimeWindowsViewWrite();
      return written;
    });
  }

  /// How many named Places take their hours from the window [windowId].
  ///
  /// This is the number a delete would take hours away from, so the delete
  /// dialog can say it.
  Future<int> placeUseCount(String windowId) async {
    final count = countAll();
    final row = await (selectOnly(places)
          ..addColumns([count])
          ..where(places.timeWindowId.equals(windowId)))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// Deletes the time window with [windowId] and detaches it from every
  /// Action and every named Place that used it.
  ///
  /// The detach is by hand: every Action that points at this window gets
  /// `time_window_id = null` and an op saying so; every Place that takes its
  /// hours from it loses them (window, hours and zone, in one op, as
  /// `PlaceDao.setPlaceHours` writes them). Only then does the row go, with a
  /// tombstone. A window that does not exist writes nothing.
  Future<void> deleteTimeWindow(String windowId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    var detached = 0;
    var detachedPlaces = 0;
    var deleted = false;
    await attachedDatabase.capturing(() async {
      final existing =
          await (select(timeWindows)..where((w) => w.id.equals(windowId)))
              .getSingleOrNull();
      if (existing == null) return;
      final attached = await (select(actions)
            ..where((a) => a.timeWindowId.equals(windowId)))
          .get();
      for (final action in attached) {
        await (update(actions)..where((a) => a.id.equals(action.id))).write(
          ActionsCompanion(
            timeWindowId: const Value(null),
            updatedAt: Value(ts),
          ),
        );
        attachedDatabase.opCapture.write(
          collection: actionsCollection,
          entityId: action.id,
          fields: {'time_window_id': null, 'updated_at': encodeInstant(ts)},
        );
      }
      detached = attached.length;
      final usingPlaces = await (select(places)
            ..where((p) => p.timeWindowId.equals(windowId)))
          .get();
      for (final place in usingPlaces) {
        await (update(places)..where((p) => p.id.equals(place.id))).write(
          PlacesCompanion(
            timeWindowId: const Value(null),
            hours: const Value(null),
            timeZone: const Value(null),
            updatedAt: Value(ts),
          ),
        );
        attachedDatabase.opCapture.write(
          collection: placesCollection,
          entityId: place.id,
          fields: {
            'time_window_id': null,
            'hours': null,
            'time_zone': null,
            'updated_at': encodeInstant(ts),
          },
        );
      }
      detachedPlaces = usingPlaces.length;
      await (delete(timeWindows)..where((w) => w.id.equals(windowId))).go();
      attachedDatabase.opCapture.tombstone(
        collection: timeWindowsCollection,
        entityId: windowId,
      );
      deleted = true;
    });
    if (detached > 0) attachedDatabase.notifyActionsViewWrite();
    if (detachedPlaces > 0) attachedDatabase.notifyPlacesViewWrite();
    if (deleted) attachedDatabase.notifyTimeWindowsViewWrite();
  }

  /// Whether a name may be stored: not blank, and at most
  /// [TimeWindows.maxNameLength] characters.
  static bool _isAcceptableName(String trimmed) =>
      trimmed.isNotEmpty && trimmed.length <= TimeWindows.maxNameLength;
}
