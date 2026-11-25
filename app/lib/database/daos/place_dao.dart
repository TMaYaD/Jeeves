/// DAO for the Places — the named places and the one-time pins (issue #239).
///
/// A Place is a point plus an area (see `models/place_area.dart`). The named
/// ones are the user's own list; a one-time pin belongs to the single Action
/// that points at it and is never listed anywhere.
///
/// Every write runs inside [GtdDatabase.capturing] and describes its effect to
/// the op log, so a Place made on one device reaches the others.
///
/// **There is no SQL foreign key from `actions.place_id` to `places.id`** — the
/// log has none, and a reference to a Place that no longer exists has to stay
/// representable (a dangling reference reads as "no place"; it never hides
/// anything). So the delete path detaches by hand: every Action that points
/// at the Place gets `place_id = null` and an op saying so, and only then does
/// the row go — with a tombstone, so a replayed create cannot bring it back.
library;

import 'package:drift/drift.dart';

import '../../models/place_area.dart';
import '../../models/time_window_hours.dart';
import '../../sync/collection_codecs.dart';
import '../../utils/uuid.dart';
import '../gtd_database.dart';

part 'place_dao.g.dart';

/// The `kind` a user-named Place carries.
const String namedPlaceKind = 'named';

/// The `kind` a one-time pin carries.
const String pinPlaceKind = 'pin';

@DriftAccessor(tables: [Places, Actions, TimeWindows])
class PlaceDao extends DatabaseAccessor<GtdDatabase> with _$PlaceDaoMixin {
  PlaceDao(super.db);

  /// The user's named places, in name order.
  ///
  /// A one-time pin is never in this list: it belongs to the one Action that
  /// points at it, and it goes when that reference moves away.
  Stream<List<Place>> watchNamedPlaces() {
    return (select(places)
          ..where((p) => p.kind.equals(namedPlaceKind))
          ..orderBy([(p) => OrderingTerm.asc(p.name)]))
        .watch();
  }

  /// Creates a named Place and returns its id, or null when the write is
  /// refused.
  ///
  /// Refused: a blank name, a name longer than [Places.maxNameLength], a
  /// point off the globe, or a radius outside [PlaceArea.minRadiusMeters] …
  /// [PlaceArea.maxRadiusMeters]. A refused write stores nothing and authors
  /// no op.
  Future<String?> createNamedPlace({
    required String name,
    required double latitudeDegrees,
    required double longitudeDegrees,
    int? radiusMeters,
    required String userId,
    DateTime? now,
  }) {
    final trimmed = name.trim();
    if (!_isAcceptableName(trimmed)) return Future.value(null);
    final area = PlaceArea.create(
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      radiusMeters: radiusMeters,
    );
    if (area == null) return Future.value(null);
    final ts = (now ?? DateTime.now()).toUtc();
    return attachedDatabase.capturing(() async {
      final id = uuid.v4();
      await into(places).insert(
        PlacesCompanion(
          id: Value(id),
          userId: Value(userId),
          kind: const Value(namedPlaceKind),
          name: Value(trimmed),
          latitudeMicrodegrees: Value(area.latitudeMicrodegrees),
          longitudeMicrodegrees: Value(area.longitudeMicrodegrees),
          radiusMeters: Value(area.radiusMeters),
          createdAt: Value(ts),
        ),
      );
      // Creation asserts the full field set, so a peer that has never seen
      // the Place can build the whole row.
      attachedDatabase.opCapture.write(
        collection: placesCollection,
        entityId: id,
        fields: {
          'user_id': userId,
          'kind': namedPlaceKind,
          'name': trimmed,
          'latitude_microdegrees': area.latitudeMicrodegrees,
          'longitude_microdegrees': area.longitudeMicrodegrees,
          'radius_meters': area.radiusMeters,
          'created_at': encodeInstant(ts),
        },
      );
      return id;
    }).then((id) {
      attachedDatabase.notifyPlacesViewWrite();
      return id;
    });
  }

  /// Updates a named Place: any of its name, its point and its radius.
  ///
  /// Returns whether the row was written. A refused update — a blank or
  /// over-long name, a point off the globe, a radius outside the accepted
  /// range, half a point — writes nothing and authors no op. So does an
  /// update of a Place that does not exist, and an update whose values did
  /// not change.
  ///
  /// **The point is a unit**: move it by giving both coordinates; one on its
  /// own is refused. The radius is the area around the point and moves on
  /// its own.
  ///
  /// Only the fields the caller actually named are written and asserted, so
  /// an edit of one field never carries a stale value of another.
  Future<bool> updateNamedPlace({
    required String placeId,
    String? name,
    double? latitudeDegrees,
    double? longitudeDegrees,
    int? radiusMeters,
    DateTime? now,
  }) {
    final trimmedName = name?.trim();
    if (name != null && !_isAcceptableName(trimmedName!)) {
      return Future.value(false);
    }
    final movesPoint = latitudeDegrees != null || longitudeDegrees != null;
    if (movesPoint && (latitudeDegrees == null || longitudeDegrees == null)) {
      return Future.value(false);
    }
    return attachedDatabase.capturing(() async {
      final current =
          await (select(places)..where((p) => p.id.equals(placeId)))
              .getSingleOrNull();
      if (current == null) return false;

      if (radiusMeters != null &&
          (radiusMeters < PlaceArea.minRadiusMeters ||
              radiusMeters > PlaceArea.maxRadiusMeters)) {
        return false;
      }

      // The new point, validated by the model. The radius it is built with is
      // irrelevant here — the area is written only when the caller named one.
      PlaceArea? newPoint;
      if (movesPoint) {
        final candidate = PlaceArea.create(
          latitudeDegrees: latitudeDegrees!,
          longitudeDegrees: longitudeDegrees!,
          radiusMeters: radiusMeters ?? PlaceArea.defaultRadiusMeters,
        );
        if (candidate == null) return false;
        // A point that did not move is no change at all: writing it would
        // author an op for a value that stands still, and would quietly undo
        // another device's move of the point if it synced first.
        newPoint =
            (candidate.latitudeMicrodegrees == current.latitudeMicrodegrees &&
                    candidate.longitudeMicrodegrees ==
                        current.longitudeMicrodegrees)
                ? null
                : candidate;
      }

      final ts = (now ?? DateTime.now()).toUtc();
      final newName =
          (trimmedName != null && trimmedName != current.name) ? trimmedName : null;
      final newRadius = (radiusMeters != null && radiusMeters != current.radiusMeters)
          ? radiusMeters
          : null;
      if (newName == null && newPoint == null && newRadius == null) return false;

      final fields = <String, Object?>{};
      if (newName != null) fields['name'] = newName;
      if (newPoint != null) {
        fields['latitude_microdegrees'] = newPoint.latitudeMicrodegrees;
        fields['longitude_microdegrees'] = newPoint.longitudeMicrodegrees;
      }
      if (newRadius != null) fields['radius_meters'] = newRadius;
      fields['updated_at'] = encodeInstant(ts);

      await (update(places)..where((p) => p.id.equals(placeId))).write(
        PlacesCompanion(
          name: newName == null ? const Value.absent() : Value(newName),
          latitudeMicrodegrees: newPoint == null
              ? const Value.absent()
              : Value(newPoint.latitudeMicrodegrees),
          longitudeMicrodegrees: newPoint == null
              ? const Value.absent()
              : Value(newPoint.longitudeMicrodegrees),
          radiusMeters:
              newRadius == null ? const Value.absent() : Value(newRadius),
          updatedAt: Value(ts),
        ),
      );
      attachedDatabase.opCapture.write(
        collection: placesCollection,
        entityId: placeId,
        fields: fields,
      );
      return true;
    }).then((written) {
      if (written) attachedDatabase.notifyPlacesViewWrite();
      return written;
    });
  }

  /// Sets the hours a named Place carries, and the zone they are read on
  /// (issue #1074).
  ///
  /// A Place has **one** source of hours: the named time window [timeWindowId]
  /// names, or hours of its own ([hours]). The two are exclusive, and this
  /// write refuses both at once. Passing neither clears the Place's hours —
  /// the window, the own hours and the zone all go.
  ///
  /// The zone travels with the hours: [timeZone] is the IANA name the hours
  /// are read on, and null reads them on the phone's clock. A Place with no
  /// hours has no zone either, so a zone is only stored alongside hours.
  ///
  /// Refused: a one-time pin (only a named Place carries hours), a Place that
  /// does not exist, both kinds of hours at once, and a [timeWindowId] that
  /// names no time window. A refused write stores nothing and authors no op.
  ///
  /// Returns whether the row was written. A write that changes nothing writes
  /// nothing and authors no op.
  Future<bool> setPlaceHours({
    required String placeId,
    String? timeWindowId,
    TimeWindowHours? hours,
    String? timeZone,
    DateTime? now,
  }) {
    return attachedDatabase.capturing(() async {
      final current = await (select(places)..where((p) => p.id.equals(placeId)))
          .getSingleOrNull();
      if (current == null) return false;
      // Only a named Place carries hours: a pin belongs to the one Action that
      // points at it and is never listed, so it has no hours of its own.
      if (current.kind != namedPlaceKind) return false;
      // One source of hours: a window, or hours of the Place's own.
      if (timeWindowId != null && hours != null) return false;
      if (timeWindowId != null) {
        final window = await (select(timeWindows)
              ..where((w) => w.id.equals(timeWindowId)))
            .getSingleOrNull();
        if (window == null) return false;
      }

      final newHoursText = hours?.encode();
      // The three fields travel together: no hours means no zone.
      final newTimeZone =
          (timeWindowId == null && hours == null) ? null : timeZone;
      // A write that changes nothing writes nothing: an op for a value that
      // stands still would undo another device's change if it synced first.
      if (current.timeWindowId == timeWindowId &&
          current.hours == newHoursText &&
          current.timeZone == newTimeZone) {
        return false;
      }

      final ts = (now ?? DateTime.now()).toUtc();
      await (update(places)..where((p) => p.id.equals(placeId))).write(
        PlacesCompanion(
          timeWindowId: Value(timeWindowId),
          hours: Value(newHoursText),
          timeZone: Value(newTimeZone),
          updatedAt: Value(ts),
        ),
      );
      // One op, all three fields: a peer never sees a window and own hours
      // side by side.
      attachedDatabase.opCapture.write(
        collection: placesCollection,
        entityId: placeId,
        fields: {
          'time_window_id': timeWindowId,
          'hours': newHoursText,
          'time_zone': newTimeZone,
          'updated_at': encodeInstant(ts),
        },
      );
      return true;
    }).then((written) {
      if (written) attachedDatabase.notifyPlacesViewWrite();
      return written;
    });
  }

  /// Deletes the Place with [placeId] — a named place or a one-time pin — and
  /// detaches it from every Action that used it.
  ///
  /// The detach is by hand: every Action that points at this Place gets
  /// `place_id = null` and an op saying so, and only then does the row go,
  /// with a tombstone. A Place that does not exist writes nothing.
  Future<void> deletePlace(String placeId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    var detached = 0;
    var deleted = false;
    await attachedDatabase.capturing(() async {
      final existing =
          await (select(places)..where((p) => p.id.equals(placeId)))
              .getSingleOrNull();
      if (existing == null) return;
      final attached =
          await (select(actions)..where((a) => a.placeId.equals(placeId))).get();
      for (final action in attached) {
        await (update(actions)..where((a) => a.id.equals(action.id))).write(
          ActionsCompanion(
            placeId: const Value(null),
            updatedAt: Value(ts),
          ),
        );
        attachedDatabase.opCapture.write(
          collection: actionsCollection,
          entityId: action.id,
          fields: {'place_id': null, 'updated_at': encodeInstant(ts)},
        );
      }
      detached = attached.length;
      await (delete(places)..where((p) => p.id.equals(placeId))).go();
      attachedDatabase.opCapture.tombstone(
        collection: placesCollection,
        entityId: placeId,
      );
      deleted = true;
    });
    if (detached > 0) attachedDatabase.notifyActionsViewWrite();
    if (deleted) attachedDatabase.notifyPlacesViewWrite();
  }

  /// The user's named places, each with the number of live Outcomes that use
  /// it, most recently used first (issue #55).
  ///
  /// "Most recently used" is the newest write to an Action that points at the
  /// Place: a Place does not itself remember being chosen. A Place no live
  /// Action uses sorts after the ones in use, by name.
  ///
  /// The count is of Outcomes that are not done whose **winning** current
  /// Action points at the Place — the same Action the place gate reads, so
  /// the count and the gate never disagree. An Outcome with two current
  /// Actions, as a sync conflict can leave behind, counts once, for the one
  /// that wins.
  Stream<List<NamedPlaceWithUse>> watchNamedPlacesWithUseCount() {
    return customSelect(
      'SELECT places.id AS id, places.name AS name, '
      'places.latitude_microdegrees AS latitude_microdegrees, '
      'places.longitude_microdegrees AS longitude_microdegrees, '
      'places.radius_meters AS radius_meters, '
      'COUNT(t.id) AS use_count '
      'FROM places '
      'LEFT JOIN actions a ON a.place_id = places.id AND a.role = \'current\' '
      'AND a.id = ('
      'SELECT mca.id FROM actions mca '
      'WHERE mca.outcome_id = a.outcome_id AND mca.role = \'current\' '
      // The same rule [_winnerFirst] applies, spelled for the subquery's
      // alias: greatest COALESCE(updated_at, created_at), then smallest id.
      'ORDER BY COALESCE(mca.updated_at, mca.created_at) DESC, mca.id ASC '
      'LIMIT 1) '
      'LEFT JOIN todos t ON t.id = a.outcome_id AND t.done_at IS NULL '
      'WHERE places.kind = ? '
      'GROUP BY places.id '
      'ORDER BY MAX(CASE WHEN t.id IS NOT NULL '
      'THEN COALESCE(a.updated_at, a.created_at) END) DESC, places.name',
      variables: [Variable(namedPlaceKind)],
      readsFrom: {places, actions, todos},
    ).watch().map((rows) {
      final result = <NamedPlaceWithUse>[];
      for (final row in rows) {
        final area = PlaceArea.fromStored(
          latitudeMicrodegrees: row.read<int>('latitude_microdegrees'),
          longitudeMicrodegrees: row.read<int>('longitude_microdegrees'),
          radiusMeters: row.read<int>('radius_meters'),
        );
        // A stored point off the globe is not a place: the row is skipped.
        if (area == null) continue;
        result.add((
          id: row.read<String>('id'),
          name: row.read<String>('name'),
          area: area,
          useCount: row.read<int>('use_count'),
        ));
      }
      return result;
    });
  }

  /// Whether a name may be stored: not blank, and at most
  /// [Places.maxNameLength] characters.
  static bool _isAcceptableName(String trimmed) =>
      trimmed.isNotEmpty && trimmed.length <= Places.maxNameLength;
}

/// A named Place with the number of live Outcomes that use it.
///
/// "Use" means the winning current Action of an Outcome that is not done
/// carries the Place — the same Action the place gate reads. A Place nobody
/// uses is still in the list — the user made it, and deleting it is their
/// call.
typedef NamedPlaceWithUse = ({
  String id,
  String name,
  PlaceArea area,
  int useCount,
});
