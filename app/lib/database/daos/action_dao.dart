/// DAO owning the Action lifecycle primitives (ADR-0001 story 2, issue #472).
///
/// An [Action] is a first-class entity against an Outcome (`todos`); this DAO
/// is the single writer of the `actions` table in-app. Every *public* mutating
/// primitive:
///
/// * runs inside a transaction so a partial write can never land,
/// * stamps `Outcome.last_clarified_at` once, through [_stampOutcome] — the
///   stamping rule (CONTEXT.md § Clarification: every Action mutation is a
///   clarifying micro-act) is encoded here and nowhere else, and
/// * self-notifies after commit: the GTD surfaces read across
///   `todos`, `actions` and `time_logs`, so a watcher naming one has to hear
///   about a write to another — the write path calls
///   [GtdDatabase.notifyActionsViewWrite] itself, plus
///   [GtdDatabase.notifyTodosViewWrite] whether or not it touched `todos`.
///
/// **The one exception to the stamping rule is [completeCurrentAction]**
/// (ADR-0001 story 4): finishing the current Action is an *engagement* signal,
/// not a clarifying act (CONTEXT.md § Clarification), so it must leave
/// `last_clarified_at` where it is — that is exactly what makes the Outcome owe
/// a re-clarification the moment its Action is done. It writes nothing to
/// `todos` at all, so its `todos` notification cannot be gated on `stamped`
/// (always false here) and is issued unconditionally instead.
///
/// Supersession carries no linkage metadata: a superseded
/// row's terminal timestamp is its `updated_at`, there is no `superseded_by_id`
/// / `superseded_at`. A text edit of an Action is an *in-place* edit of the
/// same row (a refinement of the same Action); supersession is an explicit
/// affordance that flips `role`. It is now UI-reachable through
/// [supersedeAndPromote] — the "Replace current action" gesture of the planned
/// queue (ADR-0004 story 5) and through [clearCurrentAction], which backs the
/// **Abandon** affordance of the Outcome detail view (story 8, issue #478) — so
/// it is no longer test-only.
///
/// **History (story 8, issue #478).** Terminated Actions stay attached to their
/// Outcome and are read back newest-first by [watchTerminatedActions]. A
/// terminated row is a record: nothing re-promotes it, edits it, or deletes it
/// (ADR-0004 — the promote primitive refuses any role but
/// `planned`), and no successor link exists to render.
///
/// **The planned queue (ADR-0004 story 5, issue #475).** Beyond the 0..1
/// `current` Action, an Outcome carries an ordered list of `planned` Actions —
/// externalised "what's next" thinking that is *not* engageable (it never
/// surfaces on Next / Focus / Today's Plan; every current-Action read filters
/// `role='current'`, so planned rows cannot leak). Ordering is a dense
/// `position` 0..n-1 per Outcome; reads tie-break `position, created_at, id` so
/// a cross-device duplicate/gap still renders deterministically, and the next
/// planned-queue write re-densifies. The primitives are [addPlannedAction] /
/// [reorderPlannedActions] / [promotePlannedAction] / [supersedeAndPromote] /
/// [demoteCurrentAction] / [removePlannedAction]; each stamps
/// `last_clarified_at` (CONTEXT.md § Clarification lists promote / demote /
/// reorder / remove among the stamping micro-acts), except a no-op reorder
/// (unchanged order writes nothing and does not stamp).
///
/// **The `actions` table is the only grain.** The legacy
/// `todos.next_action_text` cursor was retired by abandonment (issue
/// #479) and then dropped from the schema outright (issue #525). A
/// future contributor who re-adds an Outcome-column mirror of the current
/// Action's text, to keep two sides agreeing, would be re-introducing the
/// second source of truth this model exists to remove.
///
/// **[setTimeContext] is the second exception** (issue #238): attaching a
/// TimeContext is Organising — it does not stamp `last_clarified_at`
/// (docs/proposals/blockers-and-contexts.md). The value lives on the Action row
/// and no primitive copies it onto a successor.
///
/// **The Place and the named time window are the third** (issue #239):
/// attaching either does not stamp `last_clarified_at` either — a gate on the
/// Action is not a thought about its Outcome. Both live on the Action row, and
/// no primitive copies them onto a successor.
///
/// What primitives *do* still mirror onto `todos` is Action **metadata**
/// (`energy_level` / `time_estimate`), which is a separate mechanism with a
/// live reader: the per-field D2 COALESCE fallback. See
/// [applySupersedeCurrentAction], [_promoteRow] and [applyEditAction] — the
/// last of which mirrors whenever the row it edits is `current`, so no caller
/// has to know a row's role to keep D1.
///
/// The legacy one-field surfaces in [TodoDao] compose these primitives through
/// the `apply*` transaction-body variants (package-internal), which run inside
/// the caller's transaction and defer notification to the caller (so watchers
/// never re-read pre-commit state) — see `TodoDao.setCurrentActionText` /
/// `applyRouting` / `deleteOutcome`.
library;

import 'package:drift/drift.dart';
import '../../utils/uuid.dart';

import '../../models/action_place_and_time_window.dart';
import '../../models/current_action.dart';
import '../../models/place_area.dart';
import '../../models/time_context.dart';
import '../../models/time_window_hours.dart';
import '../../models/timeboxed.dart';
import '../../sync/collection_codecs.dart';
import '../gtd_database.dart';
import 'place_dao.dart' show namedPlaceKind, pinPlaceKind;
import 'sprint_dao.dart' show SprintDao;
import 'time_log_dao.dart' show TimeLogDao;

part 'action_dao.g.dart';

/// The effect of an Action apply-step, so a caller can notify precisely after
/// its own transaction commits: [changed] iff any `actions` row was written,
/// [stamped] iff `last_clarified_at` was moved on the Outcome, [logChanged] iff
/// a `time_logs` row was written by the terminal-transition hook (issue #476) —
/// which the caller uses to fire the TimeLog notification, since the active-log
/// and time-spent watchers do not name `actions`.
typedef ActionWriteEffect = ({bool changed, bool stamped, bool logChanged});

const ActionWriteEffect _noEffect =
    (changed: false, stamped: false, logChanged: false);

/// What an Action's Place write changed (issue #239): [changed] iff the
/// `actions` row was written, [placesChanged] iff a one-time pin row went with
/// it — a pin belongs to the one Action that points at it, so a reference that
/// moves away takes the pin with it.
typedef ActionPlaceWriteEffect = ({bool changed, bool placesChanged});

/// What an Action's pin write changed: [pinId] the new pin's id (null when
/// the write was refused), [changed] iff the `actions` row was written,
/// [placesChanged] iff a `places` row went with it.
typedef ActionPinWriteEffect =
    ({String? pinId, bool changed, bool placesChanged});

/// One row of an Outcome's history (ADR-0001 story 8, issue #478): a terminated
/// [Action] with the minutes logged against *that* Action, derived at read time
/// from `time_logs` ([TimeLogDao.totalMinutesSubqueryForAction]) rather than
/// stored anywhere.
typedef TerminatedAction = ({Action action, int loggedMinutes});

/// A current Action together with the time window row it points at, joined so
/// one query answers both (issue #55). The window is null when the Action
/// carries none, or names a window that no longer exists.
typedef _ActionWithWindow = ({Action action, TimeWindow? window});

@DriftAccessor(tables: [Actions, Todos, TimeLogs, Places, TimeWindows])
class ActionDao extends DatabaseAccessor<GtdDatabase> with _$ActionDaoMixin {
  ActionDao(super.db);

  // ---------------------------------------------------------------------------
  // Op-log capture (#550). Capture rides at the *effect* level: the `apply*`
  // transaction bodies and the private row mutations they share
  // (`_promoteRow`, `_retire`, `_insertCurrentAction`, `_stampOutcome`,
  // `_closeOpenLogFor` / `_reopenLogAgainst`, `_shiftPlannedFrom`) each
  // describe what they wrote, so every public wrapper inherits coverage from
  // the effect it delegates to. The public wrappers open the capture scope.
  //
  // The multi-current repair (`_resolveCurrentAction`) goes through the seam
  // like any other write: the reducer never knows the single-current
  // invariant, so a repair has to be an ordinary op.
  // ---------------------------------------------------------------------------

  void _captureAction(String actionId, Map<String, Object?> fields) {
    attachedDatabase.opCapture.write(
      collection: actionsCollection,
      entityId: actionId,
      fields: fields,
    );
  }

  void _captureOutcome(String outcomeId, Map<String, Object?> fields) {
    attachedDatabase.opCapture.write(
      collection: todosCollection,
      entityId: outcomeId,
      fields: fields,
    );
  }

  // ---------------------------------------------------------------------------
  // Public primitives — each opens a transaction and notifies after commit.
  // ---------------------------------------------------------------------------

  /// Compatibility-shaped entry point the legacy one-field surfaces drive:
  /// create the Outcome's `current` Action if none exists, otherwise **edit it
  /// in place** (same row, same identity — a text edit is a refinement, never a
  /// supersession). Identical text with no differing metadata is a
  /// no-op (no write, no stamp, no notify).
  ///
  /// Blank [text] is a caller error here — the legacy one-field shims route a
  /// blank write through [clearCurrentAction] instead.
  Future<void> setCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applySetCurrentAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// In-place field edit of an Action by its id — role-agnostic, so it edits a
  /// `current` row (story 7 metadata) or a `planned` row (the planned queue's
  /// inline edit, story 5) with the same UPDATE [setCurrentAction] uses for
  /// text. No-op if the row is gone or nothing differs.
  ///
  /// A `null` typed argument is "no change"; pass the matching `clear*` flag to
  /// null a nullable metadata column (same convention as [TodoDao.updateFields],
  /// which drives this in the same transaction for the metadata mirror).
  ///
  /// Editing a `current` row is safe: [applyEditAction] mirrors the resulting
  /// effort values onto the Outcome columns itself, so D1 holds whatever the
  /// row's role turns out to be at write time.
  Future<void> editAction(
    String actionId, {
    String? text,
    String? energyLevel,
    int? timeEstimate,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyEditAction(
        actionId,
        text: text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        clearEnergyLevel: clearEnergyLevel,
        clearTimeEstimate: clearTimeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Set ([value]) or clear (null) the TimeContext of the Action [actionId].
  /// Does not stamp `last_clarified_at` (Organising). No-op when the row is
  /// gone or already holds the same value.
  Future<void> setTimeContext(
    String actionId,
    TimeContext? value, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final changed = await attachedDatabase.capturing(
      () => applySetTimeContext(actionId, value, ts: ts),
    );
    if (changed) {
      attachedDatabase.notifyActionsViewWrite();
      attachedDatabase.notifyTodosViewWrite();
    }
  }

  /// Transaction-body variant of [setTimeContext]; returns whether it wrote.
  ///
  /// A named time window and a TimeContext are exclusive (issue #239): setting
  /// a TimeContext clears the window in the same write, so an Action is gated
  /// by one time and not two.
  Future<bool> applySetTimeContext(
    String actionId,
    TimeContext? value, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return false;
    final encoded = value?.encode();
    final setsContext = value != null;
    // Setting a TimeContext clears the window, so a row that already holds
    // that TimeContext *and* a window is not settled yet.
    final settled = row.timeContext == encoded &&
        (!setsContext || row.timeWindowId == null);
    if (settled) return false;
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        timeContext: Value(encoded),
        timeWindowId: setsContext ? const Value(null) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'time_context': encoded,
      if (setsContext) 'time_window_id': null,
      'updated_at': encodeInstant(ts),
    });
    return true;
  }

  // ---------------------------------------------------------------------------
  // Place and time window (issue #239).
  //
  // An Action carries at most one Place — a named one, or a one-time pin — and
  // at most one time: a named time window, or the one-time TimeContext. The
  // two are exclusive, and setting one clears the other in the same write.
  //
  // Like [setTimeContext], attaching one does not stamp `last_clarified_at`:
  // a gate on the Action is not a thought about its Outcome.
  // ---------------------------------------------------------------------------

  /// Set ([placeId]) or clear (null) the named Place of the Action [actionId].
  ///
  /// The Place must exist and be a named one: a one-time pin is set with
  /// [setPin], and a Place that does not exist is refused rather than stored
  /// as a reference to nothing.
  ///
  /// Returns whether the row was written. A no-op — the Action is gone, or it
  /// already carries that Place — writes nothing.
  ///
  /// A one-time pin the Action stops pointing at goes with the reference: the
  /// pin row is deleted and tombstoned in the same transaction, so no device
  /// keeps a pin nobody points at. A named Place is left alone — it belongs
  /// to the user's list.
  Future<bool> setNamedPlace(
    String actionId,
    String? placeId, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applySetNamedPlace(actionId, placeId, ts: ts),
    );
    if (effect.changed) {
      attachedDatabase.notifyActionsViewWrite();
      attachedDatabase.notifyTodosViewWrite();
    }
    if (effect.placesChanged) attachedDatabase.notifyPlacesViewWrite();
    return effect.changed;
  }

  /// Transaction-body variant of [setNamedPlace].
  Future<ActionPlaceWriteEffect> applySetNamedPlace(
    String actionId,
    String? placeId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return (changed: false, placesChanged: false);
    if (placeId != null) {
      final place = await (select(places)..where((p) => p.id.equals(placeId)))
          .getSingleOrNull();
      if (place == null || place.kind != namedPlaceKind) {
        return (changed: false, placesChanged: false);
      }
    }
    if (row.placeId == placeId) return (changed: false, placesChanged: false);
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        placeId: Value(placeId),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'place_id': placeId,
      'updated_at': encodeInstant(ts),
    });
    final placesChanged = await _dropPinIfAny(row.placeId);
    return (changed: true, placesChanged: placesChanged);
  }

  /// Sets a one-time pin — a Place of the Action's own — and points the Action
  /// at it. Returns the pin's id, or null when the write is refused.
  ///
  /// The pin is a `places` row of kind `pin`, never listed anywhere: it belongs
  /// to this one Action and goes when the reference moves away. [name] is
  /// optional; an over-long one is refused.
  ///
  /// A pin replaces whatever Place the Action carried, and only a pin is
  /// dropped for it — a named Place belongs to the user's list and stays in it.
  Future<String?> setPin(
    String actionId,
    PlaceArea area, {
    String? name,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    if (_pinName(name).refused) {
      return null;
    }
    final effect = await attachedDatabase.capturing(
      () => applySetPin(actionId, area, name: name, ts: ts),
    );
    if (effect.changed) {
      attachedDatabase.notifyActionsViewWrite();
      attachedDatabase.notifyTodosViewWrite();
      attachedDatabase.notifyPlacesViewWrite();
    }
    return effect.pinId;
  }

  /// Transaction-body variant of [setPin].
  ///
  /// Writes the pin and points the Action at it inside the caller's
  /// transaction, so a pin can land in the same write as the Action it
  /// belongs to. [ts] is the instant the row carries.
  ///
  /// Returns the pin's id (null when the write is refused), whether the
  /// `actions` row was written, and whether a `places` row went with it.
  Future<ActionPinWriteEffect> applySetPin(
    String actionId,
    PlaceArea area, {
    String? name,
    required DateTime ts,
  }) async {
    final pin = _pinName(name);
    if (pin.refused) {
      return (pinId: null, changed: false, placesChanged: false);
    }
    final pinName = pin.name;
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) {
      return (pinId: null, changed: false, placesChanged: false);
    }
    final pinId = uuid.v4();
    await into(places).insert(
      PlacesCompanion(
        id: Value(pinId),
        userId: Value(row.userId),
        kind: const Value(pinPlaceKind),
        name: Value(pinName),
        latitudeMicrodegrees: Value(area.latitudeMicrodegrees),
        longitudeMicrodegrees: Value(area.longitudeMicrodegrees),
        radiusMeters: Value(area.radiusMeters),
        createdAt: Value(ts),
      ),
    );
    // Creation asserts the whole row, so a peer that has never seen the pin
    // can build it.
    attachedDatabase.opCapture.write(
      collection: placesCollection,
      entityId: pinId,
      fields: {
        'user_id': row.userId,
        'kind': pinPlaceKind,
        'name': pinName,
        'latitude_microdegrees': area.latitudeMicrodegrees,
        'longitude_microdegrees': area.longitudeMicrodegrees,
        'radius_meters': area.radiusMeters,
        'created_at': encodeInstant(ts),
      },
    );
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        placeId: Value(pinId),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'place_id': pinId,
      'updated_at': encodeInstant(ts),
    });
    await _dropPinIfAny(row.placeId);
    return (pinId: pinId, changed: true, placesChanged: true);
  }

  /// The name a pin carries, or a refusal.
  ///
  /// The name is trimmed; a blank one is no name at all. A name longer than
  /// [Places.maxNameLength] is refused: the column carries no length
  /// constraint of its own, so the write path is where the rule is enforced.
  static ({bool refused, String? name}) _pinName(String? name) {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.length > Places.maxNameLength) {
      return (refused: true, name: null);
    }
    return (
      refused: false,
      name: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    );
  }

  /// Set ([windowId]) or clear (null) the time window of the Action [actionId].
  ///
  /// A named window and a TimeContext are exclusive: setting a window clears
  /// the TimeContext in the same write, so an Action is gated by one time and
  /// not two. Clearing the window leaves the TimeContext alone — there was
  /// none.
  ///
  /// The window must exist; one that does not is refused rather than stored as
  /// a reference to nothing.
  ///
  /// Returns whether the row was written. A no-op — the Action is gone, or it
  /// already carries that window — writes nothing.
  Future<bool> setTimeWindow(
    String actionId,
    String? windowId, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final changed = await attachedDatabase.capturing(
      () => applySetTimeWindow(actionId, windowId, ts: ts),
    );
    if (changed) {
      attachedDatabase.notifyActionsViewWrite();
      attachedDatabase.notifyTodosViewWrite();
    }
    return changed;
  }

  /// Transaction-body variant of [setTimeWindow].
  Future<bool> applySetTimeWindow(
    String actionId,
    String? windowId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return false;
    if (windowId != null) {
      final window =
          await (select(timeWindows)..where((w) => w.id.equals(windowId)))
              .getSingleOrNull();
      if (window == null) return false;
    }
    // Setting a window clears the TimeContext, so a row that already holds
    // that window *and* a TimeContext is not settled yet.
    final settled = row.timeWindowId == windowId &&
        (windowId == null || row.timeContext == null);
    if (settled) return false;
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        timeWindowId: Value(windowId),
        timeContext:
            windowId == null ? const Value.absent() : const Value(null),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'time_window_id': windowId,
      if (windowId != null) 'time_context': null,
      'updated_at': encodeInstant(ts),
    });
    return true;
  }

  /// Clears both time gates of the Action [actionId] — the named window and
  /// the one-time TimeContext — in one write.
  ///
  /// The two are exclusive when either is *set*, but the row can carry both:
  /// the sheet's Clear says "this Action has no time", so it takes both away,
  /// and it takes them in one write so that a peer never sees one without the
  /// other.
  ///
  /// Returns whether the row was written. A no-op — the Action is gone, or it
  /// carries no time at all — writes nothing.
  Future<bool> applyClearTime(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return false;
    if (row.timeWindowId == null && row.timeContext == null) return false;
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        timeWindowId: const Value(null),
        timeContext: const Value(null),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'time_window_id': null,
      'time_context': null,
      'updated_at': encodeInstant(ts),
    });
    return true;
  }

  /// Deletes the one-time pin row [placeId] names, when it is a pin.
  ///
  /// A pin belongs to the one Action that points at it, so a reference that
  /// moves away takes the pin with it. The row goes and a tombstone says so, so
  /// a replayed create cannot bring it back.
  ///
  /// Returns whether a pin row was dropped.
  Future<bool> _dropPinIfAny(String? placeId) async {
    if (placeId == null) return false;
    final place = await (select(places)..where((p) => p.id.equals(placeId)))
        .getSingleOrNull();
    if (place == null || place.kind != pinPlaceKind) return false;
    await (delete(places)..where((p) => p.id.equals(placeId))).go();
    attachedDatabase.opCapture.tombstone(
      collection: placesCollection,
      entityId: placeId,
    );
    return true;
  }

  /// The explicit-affordance primitive: flip the Outcome's current
  /// Action to `role='superseded'` (no linkage columns — the terminal time is
  /// `updated_at`), then, if [newActionText] is non-blank, mint a fresh
  /// `current` row. Its retire-then-mint transaction is the shape supersession
  /// takes everywhere; the planned queue's "Replace current action" gesture
  /// reaches supersession through the sibling [supersedeAndPromote] (which
  /// retires the current and flips an existing planned row up), while this
  /// text-taking variant backs [clearCurrentAction] and the re-clarify-to-new
  /// path (story 8).
  Future<void> supersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
    String? newEnergyLevel,
    int? newTimeEstimate,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applySupersedeCurrentAction(
        outcomeId,
        newActionText: newActionText,
        newEnergyLevel: newEnergyLevel,
        newTimeEstimate: newTimeEstimate,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Make the Outcome Actionless: [supersedeCurrentAction] with no replacement.
  /// Retires the current Action, so the Outcome carries none. No current row →
  /// no-op (no stamp). This is the Action side of `setCurrentActionText('')`'s
  /// blank→Actionless normalisation.
  Future<void> clearCurrentAction(String outcomeId, {DateTime? now}) =>
      supersedeCurrentAction(outcomeId, now: now);

  /// Record the current Action as **done** (ADR-0001 story 4): flip it to
  /// `role='done'` with `done_at`, and leave the Outcome in the no-current-
  /// Action state (ADR-0004 — nothing is auto-promoted; the user re-clarifies).
  ///
  /// Deliberately does **not** stamp `Outcome.last_clarified_at`: completion is
  /// the engagement signal, not clarification, so the Outcome immediately
  /// satisfies the re-clarify predicate. It writes nothing to `todos` at all.
  ///
  /// No-op on an Actionless Outcome, and idempotent: a replay finds no current
  /// row and writes nothing, so a completion can never produce two terminal
  /// rows or push the completion timestamp forward.
  Future<void> completeCurrentAction(String outcomeId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyCompleteCurrentAction(outcomeId, ts: ts),
    );
    if (effect.changed) {
      attachedDatabase.notifyActionsViewWrite();
      // Deliberately notify the `todos` view even though this transaction no
      // longer writes `todos` (the cursor clear is gone): the Outcome's own
      // list membership changes when its Action completes, and two watchers
      // list only `{todoTags, tags}` in `readsFrom`, so they would never see an
      // `actions`-only notification. This cannot ride on
      // [ActionWriteEffect.stamped], which is always false here.
      attachedDatabase.notifyTodosViewWrite();
    }
    // Completing the Action closes its open TimeLog (issue #476); the `time_logs`
    // view needs the same explicit notify as the other views.
    if (effect.logChanged) attachedDatabase.notifyTimeLogsViewWrite();
  }

  // ---------------------------------------------------------------------------
  // Planned-queue primitives (ADR-0004 story 5, issue #475). Each opens a
  // transaction, stamps, and notifies after commit.
  // ---------------------------------------------------------------------------

  /// Append (or insert at [position]) a `planned` Action on the Outcome. Blank
  /// [text] is a caller error (mirrors [setCurrentAction]). With no [position]
  /// the row lands after the last planned row; an explicit [position] inserts
  /// there and shifts the rest down. Stamps.
  Future<void> addPlannedAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    int? position,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyAddPlannedAction(
        outcomeId,
        text,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
        position: position,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Rewrite the Outcome's planned queue to dense positions `0..n-1` in
  /// [orderedIds] order. Drift-tolerant: ids not among the Outcome's planned
  /// rows are ignored, and any planned row missing from [orderedIds] is appended
  /// keeping its prior relative order (a row synced mid-drag is never lost).
  /// A no-op — the effective order is already what the store holds — writes
  /// nothing and does not stamp; otherwise stamps once for the whole gesture.
  Future<void> reorderPlannedActions(
    String outcomeId,
    List<String> orderedIds, {
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyReorderPlannedActions(outcomeId, orderedIds, ts: ts),
    );
    _notify(effect);
  }

  /// Promote a `planned` Action to `current`. Refuses (`StateError`) when the
  /// Outcome already has a current Action — the caller must use
  /// [supersedeAndPromote] for the replacing variant, so no code path silently
  /// replaces a current (ADR-0004). No-op if the row is gone, is not `planned`,
  /// or is already `current` (idempotent under double-tap / replay). Stamps.
  Future<void> promotePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyPromotePlannedAction(actionId, ts: ts),
    );
    _notify(effect);
  }

  /// The "Replace current action" gesture: in one transaction retire the
  /// Outcome's current Action (`role='superseded'` — terminal time is
  /// `updated_at`, no linkage) and flip the `planned` [actionId] up to
  /// `current`. No-op if the row is gone, already `current`, or not `planned`.
  /// Stamps once.
  ///
  /// [expectedCurrentActionId] closes the confirm-time race (issue #723): a
  /// caller that showed the user a *specific* current Action to replace passes
  /// its id, and the transaction throws [StateError] — retiring nothing — if the
  /// current Action has since changed (sync landed a different one, or cleared
  /// it) rather than superseding an Action the user never saw.
  Future<void> supersedeAndPromote(
    String actionId, {
    String? expectedCurrentActionId,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applySupersedeAndPromote(
        actionId,
        expectedCurrentActionId: expectedCurrentActionId,
        ts: ts,
      ),
    );
    _notify(effect);
  }

  /// Demote the current Action [actionId] back into the planned queue at
  /// [position] (default 0 — front of the queue, the just-committed thought
  /// stays the most-likely next candidate), shifting the existing planned rows
  /// down. No-op if the row is gone or is not `current`. Stamps.
  Future<void> demoteCurrentAction(
    String actionId, {
    int? position,
    DateTime? now,
  }) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyDemoteCurrentAction(actionId, position: position, ts: ts),
    );
    _notify(effect);
  }

  /// Hard-delete a `planned` Action (user-intent removal of an unengaged note —
  /// a planned row carries no engagement or history worth a `superseded`
  /// tombstone, ADR-0004 story 5). No-op — and never a delete — if the row is
  /// gone or is not `planned`. Stamps.
  Future<void> removePlannedAction(String actionId, {DateTime? now}) async {
    final ts = (now ?? DateTime.now()).toUtc();
    final effect = await attachedDatabase.capturing(
      () => applyRemovePlannedAction(actionId, ts: ts),
    );
    _notify(effect);
  }

  void _notify(ActionWriteEffect effect) {
    if (effect.changed) attachedDatabase.notifyActionsViewWrite();
    if (effect.stamped) attachedDatabase.notifyTodosViewWrite();
    // The terminal-transition hook (issue #476) writes `time_logs` inside the
    // Action transaction, and its watchers do not name `actions` — so they need
    // the same explicit post-commit notification.
    if (effect.logChanged) attachedDatabase.notifyTimeLogsViewWrite();
  }

  // ---------------------------------------------------------------------------
  // Reads (ADR-0001 story 3, issue #473) — the current Action *is* the answer
  // to "what is this Outcome's next move?".
  //
  // Every method below is a pure SELECT: it never opens a transaction, never
  // stamps `last_clarified_at`, never converges a multi-current set and never
  // notifies. Repair belongs to the writers (which converge as they go) and to
  // the startup sweep; a read that repaired would turn rendering a list into a
  // sync-visible write. Where a multi-current race is visible, reads apply the
  // same winner rule the writers use ([_winnerFirst]) so every surface — and
  // every device — displays the same row.
  // ---------------------------------------------------------------------------

  /// SQL ordering fragment that puts the winning `current` row first, for
  /// subselects in other DAOs' list queries (e.g. `CaptureDao`). Mirrors
  /// [_winnerFirst]; the Dart comparator stays the canonical rule.
  static const winnerFirstOrderSql =
      'ORDER BY COALESCE(actions.updated_at, actions.created_at) DESC, '
      'actions.id ASC';

  /// Correlated subquery: the winning `current` Action's [column] for the
  /// Outcome referenced by [outcomeIdRef] (a SQL expression, e.g. `'todos.id'`
  /// or `'t.id'`), or NULL when the Outcome is Actionless. Applies the same
  /// winner rule reads use ([_winnerFirst]) so a multi-current race resolves
  /// deterministically. The inner alias `mca` avoids colliding with outer
  /// table aliases.
  ///
  /// This is the single derivation of an Action-grain metadata value from the
  /// `actions` table (ADR-0001 story 7); the effective-read COALESCE that wraps
  /// it — current Action's value, else the Outcome column fallback — lives in
  /// [TodoDao.effectiveEnergyLevelSql] / [TodoDao.effectiveTimeEstimateSql],
  /// mirroring the `TimeLogDao.totalMinutesSubquery` precedent (issue #480).
  static String currentActionColumnSubquery(
    String column,
    String outcomeIdRef,
  ) =>
      '(SELECT mca.$column FROM actions mca '
      "WHERE mca.outcome_id = $outcomeIdRef AND mca.role = 'current' "
      'ORDER BY COALESCE(mca.updated_at, mca.created_at) DESC, mca.id ASC '
      'LIMIT 1)';

  /// The id of [outcomeId]'s winning `current` Action, or null when it is
  /// Actionless. Uses the blessed winner-first ordering ([winnerFirstOrderSql])
  /// so a transient multi-current race attributes to the same row every reader
  /// would display. Runs on [db]'s executor — pass the calling DAO so the read
  /// joins the caller's open transaction (Drift zone routing), which is what
  /// lets a log-opening writer resolve the Action atomically with its insert.
  ///
  /// Single home for the resolution rule so it can't drift between the two
  /// TimeLog writers ([TimeLogDao.openLog] and [FocusSessionDao.setCurrentTask]).
  static Future<String?> currentActionIdFor(
    DatabaseConnectionUser db,
    String outcomeId,
  ) async {
    final row = await db.customSelect(
      "SELECT id FROM actions WHERE outcome_id = ? AND role = 'current' "
      "$winnerFirstOrderSql LIMIT 1",
      variables: [Variable<String>(outcomeId)],
    ).getSingleOrNull();
    return row?.read<String?>('id');
  }

  /// [currentActionIdFor], except an Actionless Outcome first gets a `current`
  /// Action carrying its title (the title-as-action fallback), so a sprint
  /// started on it is attributed to a real Action that can later be completed
  /// and settle the row (#711). Runs inside the caller's transaction. Returns
  /// null only when the Outcome is gone or its title is blank.
  ///
  /// Writes the Action only — the Outcome's clarification stamp is untouched,
  /// since starting a sprint is not a clarifying act. [wroteAction] reports
  /// whether it minted one, so the caller can notify after commit.
  static Future<({String? actionId, bool wroteAction})>
      ensureCurrentActionIdFor(
    GtdDatabase db,
    String outcomeId,
    DateTime ts,
  ) async {
    final existing = await currentActionIdFor(db, outcomeId);
    if (existing != null) return (actionId: existing, wroteAction: false);
    final outcome = await (db.select(db.todos)
          ..where((t) => t.id.equals(outcomeId)))
        .getSingleOrNull();
    final title = outcome?.title.trim() ?? '';
    if (title.isEmpty) return (actionId: null, wroteAction: false);
    // The draft effort the user typed on the Actionless Outcome lands on the
    // engaged Action, as at every other creation path (ADR-0001 story 7).
    final seeded = await db.actionDao._seedMetadataFromDraft(outcomeId);
    final id = await db.actionDao._insertCurrentAction(
      outcomeId,
      title,
      energyLevel: seeded.energyLevel,
      timeEstimate: seeded.timeEstimate,
      ts: ts,
    );
    return (actionId: id, wroteAction: true);
  }

  /// The Outcome's current Action, or null when it is Actionless.
  Future<Action?> getCurrentAction(String outcomeId) async =>
      _pickWinner(await _currentActionsFor(outcomeId));

  /// Live view of the Outcome's current Action. Re-emits on any `actions`
  /// write — including one the sync bridge lands from another device, which
  /// arrives via [GtdDatabase.notifyActionsViewWrite].
  Stream<Action?> watchCurrentAction(String outcomeId) {
    return (select(actions)
          ..where((a) =>
              a.outcomeId.equals(outcomeId) & a.role.equals('current')))
        .watch()
        .map(_pickWinner);
  }

  /// Parsed TimeContext of each Outcome's current Action, keyed by Outcome id.
  /// Outcomes with none — or whose stored value does not parse — are absent, so
  /// an unreadable value never gates anything. Multi-current races resolve by
  /// the same winner rule as every other read.
  ///
  /// An Outcome whose current Action carries a named time window is absent too
  /// (issue #239): the window governs the Action's time, so the Time context
  /// beside it is ignored.
  Stream<Map<String, TimeContext>> watchCurrentTimeContexts() {
    return watchCurrentActions().map(_contextsOf);
  }

  /// One-shot sibling of [watchCurrentTimeContexts], for a surface that reads
  /// the Time contexts once when it opens and must not hold a live query.
  Future<Map<String, TimeContext>> getCurrentTimeContexts() async {
    return _contextsOf(await getCurrentActions());
  }

  /// The named time window of each Outcome's current Action, keyed by Outcome
  /// id (issue #55).
  ///
  /// Outcomes with none are absent, and so are the ones whose window row is
  /// gone or whose hours do not parse: a window the app cannot read never
  /// hides an Outcome. Multi-current races resolve by the same winner rule as
  /// every other read.
  ///
  /// Re-emits when a window is edited or deleted as well as when an Action
  /// changes: the hours a window names are part of the answer.
  Stream<Map<String, ActionTimeWindow>> watchCurrentTimeWindows() {
    return watchCurrentActions().map(_windowsOf);
  }

  /// The current Action of every Outcome, with the text it carries and the
  /// time it governs, keyed by Outcome id (issue #1073).
  ///
  /// One read, so a surface that shows an Action's words and its time shows
  /// one Action's: a time belongs to the Action and is not inherited by a
  /// successor, so a card that paired one Action's text with another's time
  /// would describe an Action that never existed.
  ///
  /// A named window governs the Action's time (issue #239): when both are set
  /// — only possible after two devices edited while apart — the Time context
  /// beside it is ignored until the next edit clears one of them.
  ///
  /// Re-emits when a window is edited or deleted as well as when an Action
  /// changes: the hours a window names are part of the answer.
  Stream<Map<String, CurrentAction>> watchCurrentActions() {
    return _currentActionsQuery().watch().map(_currentActionsByOutcome);
  }

  /// One-shot sibling of [watchCurrentActions], for a surface that reads the
  /// current Actions once and must not hold a live query.
  Future<Map<String, CurrentAction>> getCurrentActions() async {
    return _currentActionsByOutcome(await _currentActionsQuery().get());
  }

  JoinedSelectStatement _currentActionsQuery() {
    return select(actions).join([
      leftOuterJoin(timeWindows, timeWindows.id.equalsExp(actions.timeWindowId)),
    ])
      ..where(actions.role.equals('current'));
  }

  Map<String, CurrentAction> _currentActionsByOutcome(List<TypedResult> rows) {
    final byOutcome = <String, List<_ActionWithWindow>>{};
    for (final row in rows) {
      final action = row.readTable(actions);
      final window = row.readTableOrNull(timeWindows);
      (byOutcome[action.outcomeId] ??= [])
          .add((action: action, window: window));
    }
    final result = <String, CurrentAction>{};
    for (final entry in byOutcome.entries) {
      final ordered = [...entry.value]
        ..sort((a, b) => _winnerFirst(a.action, b.action));
      final winner = ordered.first;
      final action = winner.action;
      final window = winner.window;
      // A window the app cannot read — its row is gone, its hours do not
      // parse — is no window: it never hides an Outcome.
      final hours =
          window == null ? null : TimeWindowHours.tryParse(window.hours);
      final namedWindow =
          action.timeWindowId == null || window == null || hours == null
              ? null
              : (id: window.id, hours: hours, name: window.name);
      // The window governs the Action's time (issue #239): when both are set —
      // only possible after two devices edited while apart — the Time context
      // beside it is ignored until the next edit clears one of them. An
      // unreadable window still governs: the Action names one.
      final timeContext = action.timeWindowId != null
          ? null
          : TimeContext.tryParse(action.timeContext);
      result[entry.key] = (
        actionText: action.actionText,
        timeWindow: namedWindow,
        timeContext: timeContext,
      );
    }
    return result;
  }

  /// The named windows of the current Actions, keyed by Outcome id.
  static Map<String, ActionTimeWindow> _windowsOf(
    Map<String, CurrentAction> actions,
  ) {
    final result = <String, ActionTimeWindow>{};
    for (final entry in actions.entries) {
      final window = entry.value.timeWindow;
      if (window != null) result[entry.key] = window;
    }
    return result;
  }

  /// The Time contexts of the current Actions, keyed by Outcome id.
  static Map<String, TimeContext> _contextsOf(
    Map<String, CurrentAction> actions,
  ) {
    final result = <String, TimeContext>{};
    for (final entry in actions.entries) {
      final context = entry.value.timeContext;
      if (context != null) result[entry.key] = context;
    }
    return result;
  }

  /// The Place each Outcome's current Action carries, keyed by Outcome id
  /// (issue #55).
  ///
  /// The winning current Action decides, as everywhere else: a Place on a
  /// losing current row does not count. A Place that no longer exists, or one
  /// whose stored point is off the globe, is absent — a reference the app
  /// cannot read never hides the Outcome.
  ///
  /// Re-emits on a write to `places` as well as to `actions`: renaming a
  /// Place or moving its point changes what every Action carrying it
  /// resolves to.
  Stream<Map<String, ActionPlace>> watchCurrentPlaces() {
    return customSelect(
      'SELECT actions.outcome_id AS outcome_id, places.id AS place_id, '
      'places.kind AS place_kind, places.name AS place_name, '
      'places.latitude_microdegrees AS latitude_microdegrees, '
      'places.longitude_microdegrees AS longitude_microdegrees, '
      'places.radius_meters AS radius_meters '
      'FROM actions INNER JOIN places ON places.id = actions.place_id '
      "WHERE actions.role = 'current' AND actions.id = ("
      'SELECT mca.id FROM actions mca '
      'WHERE mca.outcome_id = actions.outcome_id AND mca.role = \'current\' '
      // The same rule [_winnerFirst] applies, spelled for the subquery's
      // alias: greatest COALESCE(updated_at, created_at), then smallest id.
      'ORDER BY COALESCE(mca.updated_at, mca.created_at) DESC, mca.id ASC '
      'LIMIT 1)',
      readsFrom: {actions, places},
    ).watch().map((rows) {
      final result = <String, ActionPlace>{};
      for (final row in rows) {
        final area = PlaceArea.fromStored(
          latitudeMicrodegrees: row.read<int>('latitude_microdegrees'),
          longitudeMicrodegrees: row.read<int>('longitude_microdegrees'),
          radiusMeters: row.read<int>('radius_meters'),
        );
        // A stored point off the globe is not a place: the row is skipped, so
        // the Outcome reads as carrying none.
        if (area == null) continue;
        result[row.read<String>('outcome_id')] = (
          id: row.read<String>('place_id'),
          area: area,
          name: row.readNullable<String>('place_name'),
          isPin: row.read<String>('place_kind') == pinPlaceKind,
        );
      }
      return result;
    });
  }

  /// The Place and the time window the Action [actionId] resolves to.
  ///
  /// Either half is null when the Action carries none, when the row it names
  /// no longer exists, or when the stored value cannot be read. A reference
  /// the app cannot make sense of never hides the Action: it reads as "no
  /// place" and "no window".
  ///
  /// A window and a TimeContext can both be set — only after two devices
  /// edited while apart — and the window governs: the TimeContext is ignored
  /// on read (see [watchCurrentTimeContexts]) until the next edit clears one
  /// of them.
  Future<ActionPlaceAndTimeWindow> placeAndTimeWindowFor(
    String actionId,
  ) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return const (place: null, timeWindow: null);
    return (
      place: await _resolvedPlace(row.placeId),
      timeWindow: await _resolvedTimeWindow(row.timeWindowId),
    );
  }

  /// The Place the Action [actionId] resolves to, or null.
  Future<ActionPlace?> placeFor(String actionId) async =>
      (await placeAndTimeWindowFor(actionId)).place;

  /// The time window the Action [actionId] resolves to, or null.
  Future<ActionTimeWindow?> timeWindowFor(String actionId) async =>
      (await placeAndTimeWindowFor(actionId)).timeWindow;

  /// The Place row [placeId] names, resolved — or null when there is none, when
  /// the row is gone, or when its point is off the globe.
  Future<ActionPlace?> _resolvedPlace(String? placeId) async {
    if (placeId == null) return null;
    final row = await (select(places)..where((p) => p.id.equals(placeId)))
        .getSingleOrNull();
    if (row == null) return null;
    final area = PlaceArea.fromStored(
      latitudeMicrodegrees: row.latitudeMicrodegrees,
      longitudeMicrodegrees: row.longitudeMicrodegrees,
      radiusMeters: row.radiusMeters,
    );
    if (area == null) return null;
    return (
      id: row.id,
      area: area,
      name: row.name,
      isPin: row.kind == pinPlaceKind,
    );
  }

  /// The time window row [windowId] names, resolved — or null when there is
  /// none, when the row is gone, or when its hours do not parse.
  Future<ActionTimeWindow?> _resolvedTimeWindow(String? windowId) async {
    if (windowId == null) return null;
    final row = await (select(timeWindows)..where((w) => w.id.equals(windowId)))
        .getSingleOrNull();
    if (row == null) return null;
    final hours = TimeWindowHours.tryParse(row.hours);
    if (hours == null) return null;
    return (id: row.id, hours: hours, name: row.name);
  }

  /// Whether each Outcome's current Action is Timeboxed (issue #923), keyed
  /// by Outcome id. An absent key means the Outcome is not Timeboxed.
  ///
  /// The read rule lives in [isTimeboxedAction]: the switch is on **and** the
  /// Action has an estimate. Two devices can merge "the estimate was cleared"
  /// with "the switch was turned on"; the rule reads that as off rather than
  /// as a limit of nothing.
  Stream<Map<String, bool>> watchCurrentTimeboxed() {
    return (select(actions)..where((a) => a.role.equals('current')))
        .watch()
        .map(_timeboxedByOutcome);
  }

  Map<String, bool> _timeboxedByOutcome(List<Action> rows) {
    final byOutcome = <String, List<Action>>{};
    for (final a in rows) {
      (byOutcome[a.outcomeId] ??= []).add(a);
    }
    final result = <String, bool>{};
    for (final entry in byOutcome.entries) {
      final winner = _pickWinner(entry.value);
      if (winner == null) continue;
      if (isTimeboxedAction(
        timeboxed: winner.timeboxed,
        timeEstimate: winner.timeEstimate,
      )) {
        result[entry.key] = true;
      }
    }
    return result;
  }

  /// Current Action text for each of [outcomeIds], keyed by Outcome id. An
  /// absent key means the Outcome is Actionless — the shape the one-at-a-time
  /// review snapshots consume, so a wizard step renders every item's Action
  /// without one DAO call per item.
  ///
  /// Chunked so a large snapshot cannot exceed SQLite's bound-variable limit.
  Future<Map<String, String>> getCurrentActionTexts(
    Set<String> outcomeIds,
  ) async {
    if (outcomeIds.isEmpty) return const {};
    final ids = outcomeIds.toList();
    final byOutcome = <String, List<Action>>{};
    for (var start = 0; start < ids.length; start += _idChunkSize) {
      final chunk = ids.sublist(
        start,
        (start + _idChunkSize).clamp(0, ids.length),
      );
      final rows = await (select(actions)
            ..where((a) => a.outcomeId.isIn(chunk) & a.role.equals('current')))
          .get();
      for (final row in rows) {
        (byOutcome[row.outcomeId] ??= <Action>[]).add(row);
      }
    }
    return {
      for (final entry in byOutcome.entries)
        if (_pickWinner(entry.value) case final winner?)
          entry.key: winner.actionText,
    };
  }

  /// Chunk width for `IN (…)` id lookups, well inside SQLite's default
  /// bound-variable ceiling.
  static const _idChunkSize = 500;

  /// Live view of the Outcome's planned queue, ordered `position, created_at,
  /// id` — the tie-break renders a cross-device duplicate/gap deterministically
  /// without repairing it (writers re-densify; a read never writes).
  Stream<List<Action>> watchPlannedActions(String outcomeId) =>
      _plannedQuery(outcomeId).watch();

  /// One-shot read of the Outcome's planned queue, same ordering as
  /// [watchPlannedActions].
  Future<List<Action>> getPlannedActions(String outcomeId) =>
      _plannedQuery(outcomeId).get();

  SimpleSelectStatement<$ActionsTable, Action> _plannedQuery(
    String outcomeId,
  ) =>
      select(actions)
        ..where((a) => a.outcomeId.equals(outcomeId) & a.role.equals('planned'))
        ..orderBy([
          (a) => OrderingTerm(expression: a.position),
          (a) => OrderingTerm(expression: a.createdAt),
          (a) => OrderingTerm(expression: a.id),
        ]);

  /// The Outcome's **history** (ADR-0001 story 8, issue #478): its terminated
  /// Actions — `done` and `superseded` alike — newest-first, each carrying the
  /// minutes logged against it.
  ///
  /// The terminal timestamp is `COALESCE(done_at, updated_at, created_at)`: a
  /// `done` row's is `done_at`, a `superseded` row's is `updated_at`
  /// (supersession has no dedicated column), and `created_at` catches a row
  /// that carries neither. Ties break on `id ASC`, mirroring
  /// [winnerFirstOrderSql], so two devices render the same order.
  ///
  /// Deliberately *not* shared with `TodoDao`'s Stale predicate, which uses the
  /// same COALESCE over a different role set — Stale excludes `superseded`
  /// (an abandoned Action owes nothing), history includes it. The expressions
  /// look alike and mean different things; unifying them would be a bug.
  ///
  /// Pure SELECT: no transaction, no stamp, no convergence, no notify —
  /// reading history is not clarification. Drift tracks `actions` for
  /// re-emission; the joined `time_logs` subquery is *not* tracked, which is
  /// sound because every terminal transition closes that Action's log inside
  /// the same transaction (issue #476) and nothing ever opens a log against a
  /// non-`current` row, so a terminated Action's minutes are frozen.
  Stream<List<TerminatedAction>> watchTerminatedActions(String outcomeId) {
    final (query, loggedMinutes) = _terminatedQuery(outcomeId);
    return query.watch().map((rows) => _readTerminated(rows, loggedMinutes));
  }

  /// One-shot read of the Outcome's history, same shape and ordering as
  /// [watchTerminatedActions].
  Future<List<TerminatedAction>> getTerminatedActions(String outcomeId) async {
    final (query, loggedMinutes) = _terminatedQuery(outcomeId);
    return _readTerminated(await query.get(), loggedMinutes);
  }

  /// The two terminal roles. A `planned` row is unengaged thinking and a
  /// `current` row is the live Action; neither is history.
  static const _terminalRoles = ['done', 'superseded'];

  // Drift's `join` erases the row type (its return is the raw
  // `JoinedSelectStatement`), so the added column travels back alongside the
  // statement — reading it needs the very same expression instance.
  (JoinedSelectStatement, Expression<int>) _terminatedQuery(String outcomeId) {
    // Single joined query with an added column, not one lookup per row: an
    // Outcome with a long history would otherwise cost N round-trips.
    final loggedMinutes = CustomExpression<int>(
      TimeLogDao.totalMinutesSubqueryForAction('actions.id'),
    );
    final query = select(actions).join(<Join>[])
      ..addColumns([loggedMinutes])
      ..where(actions.outcomeId.equals(outcomeId) &
          actions.role.isIn(_terminalRoles))
      ..orderBy([
        OrderingTerm(
          expression: coalesce([actions.doneAt, actions.updatedAt, actions.createdAt]),
          mode: OrderingMode.desc,
        ),
        OrderingTerm(expression: actions.id),
      ]);
    return (query, loggedMinutes);
  }

  List<TerminatedAction> _readTerminated(
    List<TypedResult> rows,
    Expression<int> loggedMinutes,
  ) =>
      [
        for (final row in rows)
          (
            action: row.readTable(actions),
            loggedMinutes: row.read(loggedMinutes) ?? 0,
          ),
      ];

  /// Read-side application of the winner rule — deterministic display of an
  /// accidental multi-current set, with nothing written.
  static Action? _pickWinner(List<Action> currents) {
    if (currents.isEmpty) return null;
    if (currents.length == 1) return currents.first;
    return ([...currents]..sort(_winnerFirst)).first;
  }

  // ---------------------------------------------------------------------------
  // Transaction-body variants — run inside the caller's transaction, never
  // notify (the caller notifies after its own commit). Used by the public
  // wrappers above and by TodoDao's writers, for which the `actions` table is
  // the only grain — the `todos.next_action_text` cursor is retired and no
  // longer exists.
  // ---------------------------------------------------------------------------

  Future<ActionWriteEffect> applySetCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    required DateTime ts,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'setCurrentAction requires non-blank text; route a blank write through '
            'clearCurrentAction',
      );
    }
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;

    if (current == null) {
      // D3 (ADR-0001 story 7): energy / time set on an Actionless Outcome live
      // on its columns as draft. When its first `current` Action is born and
      // the caller passes no metadata, seed the birth Action from those draft
      // columns — so the draft lands on the Action for *every* creation path
      // (birth here, promotion in [_promoteRow], the Actionless replacement arm
      // of [applySupersedeCurrentAction]), through the shared
      // [_seedMetadataFromDraft]. Explicit args win over the draft.
      final seeded = await _seedMetadataFromDraft(
        outcomeId,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
      );
      await _insertCurrentAction(
        outcomeId,
        normalized,
        energyLevel: seeded.energyLevel,
        timeEstimate: seeded.timeEstimate,
        ts: ts,
      );
      await _stampOutcome(outcomeId, ts);
      return (changed: true, stamped: true, logChanged: false);
    }

    final textDiffers = current.actionText != normalized;
    final metadataDiffers = (energyLevel != null &&
            energyLevel != current.energyLevel) ||
        (timeEstimate != null && timeEstimate != current.timeEstimate);
    if (!textDiffers && !metadataDiffers) {
      // No-op on the primary write; convergence of an accidental multi-current
      // set (if any) still counts as a change but never stamps.
      return (changed: resolved.converged, stamped: false, logChanged: false);
    }

    await (update(actions)..where((a) => a.id.equals(current.id))).write(
      ActionsCompanion(
        actionText: Value(normalized),
        energyLevel:
            energyLevel != null ? Value(energyLevel) : const Value.absent(),
        timeEstimate:
            timeEstimate != null ? Value(timeEstimate) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(current.id, {
      'text': normalized,
      'energy_level': ?energyLevel,
      'time_estimate': ?timeEstimate,
      'updated_at': encodeInstant(ts),
    });
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  /// **Upholds D1 for `current` rows by construction.** When the row it loaded
  /// is `role='current'`, the post-write effort values are mirrored onto
  /// `todos.energy_level` / `time_estimate` in the same transaction — the same
  /// mirror [_promoteRow] writes, for the same D2 reason. That makes D1 a
  /// property of this method rather than of caller discipline: a `planned` row
  /// that became `current` between a sheet opening and its Save (a synced write
  /// from another device, or a promote the UI has not re-emitted yet) can no
  /// longer land effort on the Action while the columns keep the old values,
  /// which would resurface as the Outcome's effective effort the moment the
  /// Action is abandoned. It is idempotent with respect to
  /// [TodoDao.updateFields], which writes the same columns first inside the
  /// same transaction.
  Future<ActionWriteEffect> applyEditAction(
    String actionId, {
    String? text,
    String? energyLevel,
    int? timeEstimate,
    bool? timeboxed,
    bool clearEnergyLevel = false,
    bool clearTimeEstimate = false,
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null) return _noEffect;

    final normalized = text?.trim();
    final textDiffers = normalized != null && normalized != row.actionText;
    // A clear differs only when the column currently holds a value; setting a
    // value differs when it is not already that value. `clear*` wins over the
    // typed argument, matching [TodoDao.updateFields].
    final energyDiffers = clearEnergyLevel
        ? row.energyLevel != null
        : energyLevel != null && energyLevel != row.energyLevel;
    final timeDiffers = clearTimeEstimate
        ? row.timeEstimate != null
        : timeEstimate != null && timeEstimate != row.timeEstimate;
    // Clearing the estimate clears the Timeboxed switch with it (issue #923):
    // a limit with no estimate is not a limit, and a later estimate must not
    // bring the old limit back.
    final timeboxedClears = clearTimeEstimate && (row.timeboxed ?? false);
    // The switch set explicitly (issue #923) — the estimate sheet offers the
    // estimate and the switch together, so they are written in one row write
    // with one timestamp. A clear wins: an estimate with no value cannot
    // limit anything.
    final timeboxedDiffers = timeboxed != null &&
        !clearTimeEstimate &&
        (row.timeboxed ?? false) != timeboxed;
    if (!textDiffers &&
        !energyDiffers &&
        !timeDiffers &&
        !timeboxedClears &&
        !timeboxedDiffers) {
      return _noEffect;
    }

    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        actionText: textDiffers ? Value(normalized) : const Value.absent(),
        energyLevel: clearEnergyLevel
            ? const Value(null)
            : energyDiffers ? Value(energyLevel) : const Value.absent(),
        timeEstimate: clearTimeEstimate
            ? const Value(null)
            : timeDiffers ? Value(timeEstimate) : const Value.absent(),
        timeboxed: timeboxedDiffers
            ? Value(timeboxed)
            : timeboxedClears
                ? const Value(false)
                : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      if (textDiffers) 'text': normalized,
      if (clearEnergyLevel)
        'energy_level': null
      else if (energyDiffers)
        'energy_level': energyLevel,
      if (clearTimeEstimate)
        'time_estimate': null
      else if (timeDiffers)
        'time_estimate': timeEstimate,
      if (timeboxedDiffers) 'timeboxed': timeboxed,
      if (timeboxedClears) 'timeboxed': false,
      'updated_at': encodeInstant(ts),
    });
    if (row.role == 'current') {
      // D1, by construction rather than by caller discipline. Mirror the
      // *post-write* effort values (not the diffs) so the columns cannot be
      // left holding a value the current Action no longer carries — exactly
      // what [_promoteRow] writes, and idempotent when [TodoDao.updateFields]
      // has already written them earlier in this transaction.
      await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
        TodosCompanion(
          energyLevel: Value(
            clearEnergyLevel ? null : energyLevel ?? row.energyLevel,
          ),
          timeEstimate: Value(
            clearTimeEstimate ? null : timeEstimate ?? row.timeEstimate,
          ),
          updatedAt: Value(ts),
        ),
      );
      _captureOutcome(row.outcomeId, {
        'energy_level':
            clearEnergyLevel ? null : energyLevel ?? row.energyLevel,
        'time_estimate':
            clearTimeEstimate ? null : timeEstimate ?? row.timeEstimate,
        'updated_at': encodeInstant(ts),
      });
    }
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applySupersedeCurrentAction(
    String outcomeId, {
    String? newActionText,
    String? newEnergyLevel,
    int? newTimeEstimate,
    required DateTime ts,
  }) async {
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;
    final newText = newActionText?.trim();
    final hasReplacement = newText != null && newText.isNotEmpty;

    var changed = resolved.converged;
    // Terminal-transition TimeLog hook (issue #476, CONTEXT.md § Switching
    // Actions: switching closes the current TimeLog and opens a new one).
    // Close the retired Action's open log; if a replacement is minted in the
    // same transaction AND a log was closed, reopen a continuation against the
    // successor so no engagement time is lost. Keep this minimal — #477 also
    // edits this method (a metadata mirror); the two additions are independent.
    TimeLog? closedLog;
    if (current != null) {
      closedLog = await _closeOpenLogFor(current.id, ts);
      await _retire(current.id, ts);
      changed = true;
    }
    if (hasReplacement) {
      // Metadata mirror (ADR-0001 story 7). When a live current Action was just
      // retired (D4), mirror the *replacement's* `energy_level` /
      // `time_estimate` onto the Outcome — not the superseded row's: the D2 read
      // fallback is a per-field COALESCE over these columns, so leaving the
      // retired Action's estimates behind would resurface them against the fresh
      // replacement (the inheritance the story forbids). But when there was no
      // current Action to retire ([current] == null), the columns are the D3
      // draft the user typed, so this replacement is a *creation* path and
      // seeds its NULL fields from that draft like a birth Action — mirroring
      // the seeded values so `todos` and the new Action agree.
      final seeded = current == null
          ? await _seedMetadataFromDraft(
              outcomeId,
              energyLevel: newEnergyLevel,
              timeEstimate: newTimeEstimate,
            )
          : (energyLevel: newEnergyLevel, timeEstimate: newTimeEstimate);
      final newActionId = await _insertCurrentAction(
        outcomeId,
        newText,
        energyLevel: seeded.energyLevel,
        timeEstimate: seeded.timeEstimate,
        ts: ts,
      );
      await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
        TodosCompanion(
          energyLevel: Value(seeded.energyLevel),
          timeEstimate: Value(seeded.timeEstimate),
          updatedAt: Value(ts),
        ),
      );
      _captureOutcome(outcomeId, {
        'energy_level': seeded.energyLevel,
        'time_estimate': seeded.timeEstimate,
        'updated_at': encodeInstant(ts),
      });
      changed = true;
      if (closedLog != null) {
        await _reopenLogAgainst(closed: closedLog, newActionId: newActionId, ts: ts);
      }
    }

    // A pure convergence with nothing to supersede and no replacement is repair,
    // not clarification — it must not stamp. Retiring a real current row or
    // minting a replacement is a clarifying act and stamps.
    // The *abandon* arm — a retirement with nothing to succeed it — writes
    // nothing to `todos` beyond the stamp below. It used to clear the cursor to
    // stop the startup sweep resurrecting the retired Action; the sweep's
    // cursor-adoption pass is deleted outright, so nothing reads the
    // cursor to resurrect anything, and the `superseded` row this leaves behind
    // needs no cursor-clear guard at all.
    final didMutate = current != null || hasReplacement;
    if (didMutate) await _stampOutcome(outcomeId, ts);
    // A `time_logs` row was written iff the retired Action had an open log to
    // close (a non-null closedLog); the reopen, when it fires, rides on that.
    return (changed: changed, stamped: didMutate, logChanged: closedLog != null);
  }

  /// Transaction-body variant of [completeCurrentAction], shared with the
  /// Outcome-completion cascade in [TodoDao] so "Outcome done closes its
  /// current Action" is encoded once. Always returns `stamped: false` — the
  /// caller decides whether *its own* act (achieving the Outcome) stamps.
  Future<ActionWriteEffect> applyCompleteCurrentAction(
    String outcomeId, {
    required DateTime ts,
  }) async {
    final resolved = await _resolveCurrentAction(outcomeId, ts);
    final current = resolved.current;
    if (current == null) {
      return (changed: resolved.converged, stamped: false, logChanged: false);
    }

    await (update(actions)..where((a) => a.id.equals(current.id))).write(
      ActionsCompanion(
        role: const Value('done'),
        doneAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(current.id, {
      'role': 'done',
      'done_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
    });
    // Engagement on this Action ended at Done — close its open TimeLog here
    // (issue #476), not at a later endFocus(). No reopen: a finished Action has
    // no successor to continue against (CONTEXT.md § Switching Actions).
    final closedLog = await _closeOpenLogFor(current.id, ts);
    // Nothing is written to `todos`: completion must not stamp, and there is
    // no Outcome-column cursor to clear — it was deleted outright, along with the adoption pass that would have needed guarding. The caller still
    // fires the `todos` view notification — see [completeCurrentAction].
    return (changed: true, stamped: false, logChanged: closedLog != null);
  }

  // ---------------------------------------------------------------------------
  // Planned-queue transaction bodies.
  // ---------------------------------------------------------------------------

  Future<ActionWriteEffect> applyAddPlannedAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    int? position,
    required DateTime ts,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'addPlannedAction requires non-blank text',
      );
    }
    final planned = await _plannedActionsFor(outcomeId);
    final int insertAt;
    if (position == null) {
      // Append after the last planned row: COALESCE(MAX(position)+1, 0).
      insertAt = planned.isEmpty
          ? 0
          : planned
                  .map((a) => a.position ?? 0)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    } else {
      insertAt = position.clamp(0, planned.length);
      await _shiftPlannedFrom(planned, insertAt, ts);
    }
    final userId = await _userIdForOutcome(outcomeId);
    final plannedId = uuid.v4();
    await into(actions).insert(
      ActionsCompanion(
        id: Value(plannedId),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(normalized),
        role: const Value('planned'),
        position: Value(insertAt),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(plannedId, {
      'outcome_id': outcomeId,
      'user_id': userId,
      'text': normalized,
      'role': 'planned',
      'position': insertAt,
      'energy_level': energyLevel,
      'time_estimate': timeEstimate,
      'created_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
      'done_at': null,
    });
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applyReorderPlannedActions(
    String outcomeId,
    List<String> orderedIds, {
    required DateTime ts,
  }) async {
    final planned = await _plannedActionsFor(outcomeId);
    if (planned.isEmpty) return _noEffect;

    final byId = {for (final row in planned) row.id: row};
    final seen = <String>{};
    final target = <Action>[];
    for (final id in orderedIds) {
      final row = byId[id];
      if (row != null && seen.add(id)) target.add(row);
    }
    // Any planned row absent from orderedIds keeps its prior relative order.
    for (final row in planned) {
      if (seen.add(row.id)) target.add(row);
    }

    // No-op when every row already sits at its target dense index; a row at the
    // wrong index means the order changed *or* positions had drifted (gap /
    // duplicate) — either way this write re-densifies.
    var changed = false;
    for (var i = 0; i < target.length; i++) {
      if (target[i].position != i) {
        changed = true;
        break;
      }
    }
    if (!changed) return _noEffect;

    for (var i = 0; i < target.length; i++) {
      if (target[i].position != i) {
        await (update(actions)..where((a) => a.id.equals(target[i].id))).write(
          ActionsCompanion(position: Value(i), updatedAt: Value(ts)),
        );
        _captureAction(target[i].id, {
          'position': i,
          'updated_at': encodeInstant(ts),
        });
      }
    }
    await _stampOutcome(outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applyPromotePlannedAction(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    final resolved = await _resolveCurrentAction(row.outcomeId, ts);
    if (resolved.current != null) {
      throw StateError(
        'promotePlannedAction: Outcome ${row.outcomeId} already has a current '
        'Action; use supersedeAndPromote to replace it',
      );
    }
    // Refused above unless the Outcome is Actionless, so this is always a
    // creation path: the promoted row's NULL fields seed from the D3 draft
    // rather than overwriting it — matching the birth-Action rule.
    await _promoteRow(row, ts, seedFromDraft: true);
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applySupersedeAndPromote(
    String actionId, {
    String? expectedCurrentActionId,
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    final resolved = await _resolveCurrentAction(row.outcomeId, ts);
    final current = resolved.current;
    // Close-the-window guard (issue #723): a caller that showed the user a
    // specific current Action to replace passes its id. If sync installed a
    // different current — or cleared it — while the confirm sheet was open,
    // retiring `current` would supersede an Action the user never saw, so abort
    // the whole transaction instead. Mirrors applyPromotePlannedAction
    // asserting its own (no-current) precondition rather than writing blind.
    if (expectedCurrentActionId != null &&
        current?.id != expectedCurrentActionId) {
      throw StateError(
        'supersedeAndPromote: current Action changed under the confirm '
        '(expected $expectedCurrentActionId, found ${current?.id})',
      );
    }
    // Terminal-transition TimeLog hook (issue #476, CONTEXT.md § Switching
    // Actions): retiring the current Action here is the same transition as in
    // supersedeCurrentAction, so it closes the retired Action's open log and,
    // because the promoted [row] is the installed successor, reopens a
    // continuation against it so no engagement time is lost.
    TimeLog? closedLog;
    // Bind the regime before the retire below: a live current being replaced
    // means the columns are its D1 mirror → overwrite them with the promoted
    // row's values (D4); an Actionless Outcome (nothing to retire) means the
    // columns are the D3 draft → seed the promoted row's NULLs from it, exactly
    // like a plain promote.
    final seedFromDraft = current == null;
    if (current != null) {
      closedLog = await _closeOpenLogFor(current.id, ts);
      await _retire(current.id, ts);
    }
    await _promoteRow(row, ts, seedFromDraft: seedFromDraft);
    if (closedLog != null) {
      await _reopenLogAgainst(closed: closedLog, newActionId: row.id, ts: ts);
    }
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: closedLog != null);
  }

  Future<ActionWriteEffect> applyDemoteCurrentAction(
    String actionId, {
    int? position,
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'current') return _noEffect;

    final planned = await _plannedActionsFor(row.outcomeId);
    final insertAt = (position ?? 0).clamp(0, planned.length);
    await _shiftPlannedFrom(planned, insertAt, ts);
    await (update(actions)..where((a) => a.id.equals(row.id))).write(
      ActionsCompanion(
        role: const Value('planned'),
        position: Value(insertAt),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(row.id, {
      'role': 'planned',
      'position': insertAt,
      'updated_at': encodeInstant(ts),
    });
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  Future<ActionWriteEffect> applyRemovePlannedAction(
    String actionId, {
    required DateTime ts,
  }) async {
    final row = await (select(actions)..where((a) => a.id.equals(actionId)))
        .getSingleOrNull();
    if (row == null || row.role != 'planned') return _noEffect;

    await (delete(actions)..where((a) => a.id.equals(actionId))).go();
    // A hard delete on the log is a tombstone op, never row absence — that is
    // what stops a replayed create from resurrecting the removed row.
    attachedDatabase.opCapture
        .tombstone(collection: actionsCollection, entityId: actionId);
    // The gap the delete leaves in `position` is display-only: the read
    // tie-break covers it and the next reorder re-densifies.
    await _stampOutcome(row.outcomeId, ts);
    return (changed: true, stamped: true, logChanged: false);
  }

  // ---------------------------------------------------------------------------
  // Shared internals.
  // ---------------------------------------------------------------------------

  Future<List<Action>> _currentActionsFor(String outcomeId) {
    return (select(actions)
          ..where((a) => a.outcomeId.equals(outcomeId) & a.role.equals('current')))
        .get();
  }

  /// The Outcome's planned rows, in queue order (shared by the planned-queue
  /// transaction bodies, which read then rewrite positions).
  Future<List<Action>> _plannedActionsFor(String outcomeId) =>
      _plannedQuery(outcomeId).get();

  /// Re-densify the planned queue and open slot [from] for a fresh row. Each
  /// ordered row lands at its dense index, with rows at or after [from] pushed
  /// one slot down; the caller then writes the incoming row at [from].
  ///
  /// [from] is a queue *index* (into the ordered [planned] list), not a raw
  /// stored `position`. Comparing index against index — rather than index
  /// against stored `position` — keeps placement correct even when stored
  /// positions have gaps or don't start at 0 (a remove leaves a gap; a
  /// cross-device sync can duplicate). Callers pass the pre-read [planned] list
  /// in queue order to avoid a re-query inside the transaction.
  Future<void> _shiftPlannedFrom(
    List<Action> planned,
    int from,
    DateTime ts,
  ) async {
    for (var i = 0; i < planned.length; i++) {
      final row = planned[i];
      final desired = i >= from ? i + 1 : i;
      if (row.position != desired) {
        await (update(actions)..where((a) => a.id.equals(row.id))).write(
          ActionsCompanion(position: Value(desired), updatedAt: Value(ts)),
        );
        _captureAction(row.id, {
          'position': desired,
          'updated_at': encodeInstant(ts),
        });
      }
    }
  }

  /// Coalesce missing effort metadata from the Outcome's D3 draft columns
  /// (ADR-0001 story 7). On an Actionless Outcome, `todos.energy_level` /
  /// `time_estimate` hold the effort the user typed with no Action to carry it;
  /// every *creation* path — birth in [applySetCurrentAction], promotion in
  /// [_promoteRow], the Actionless replacement arm of
  /// [applySupersedeCurrentAction] — routes its NULL fields through here so the
  /// draft lands on the Action being minted instead of being erased. Explicit
  /// values win: the columns are read only when a field is NULL, and not at all
  /// when both are already set.
  Future<({String? energyLevel, int? timeEstimate})> _seedMetadataFromDraft(
    String outcomeId, {
    String? energyLevel,
    int? timeEstimate,
  }) async {
    if (energyLevel != null && timeEstimate != null) {
      return (energyLevel: energyLevel, timeEstimate: timeEstimate);
    }
    final outcome = await (select(todos)..where((t) => t.id.equals(outcomeId)))
        .getSingleOrNull();
    return (
      energyLevel: energyLevel ?? outcome?.energyLevel,
      timeEstimate: timeEstimate ?? outcome?.timeEstimate,
    );
  }

  /// Flip [row] to `role='current'` (clearing `position`) and re-establish the
  /// D1 mirror — write the now-current Action's `energy_level` / `time_estimate`
  /// onto the Outcome so the D2 read fallback resolves to it. Shared by
  /// [applyPromotePlannedAction] and [applySupersedeAndPromote]; the caller
  /// stamps.
  ///
  /// [seedFromDraft] decides how a NULL on the promoted row is treated — the
  /// same `current == null` split [applySetCurrentAction] makes at a birth:
  ///
  /// * `true` — the Outcome is Actionless, so its columns are the D3 draft the
  ///   user typed. Promotion is a creation path, so a NULL field on the row
  ///   inherits the draft — onto the promoted **Action** (keeping D1 coherent)
  ///   and the mirror alike — exactly like a birth Action. Explicit row values
  ///   still win.
  /// * `false` — a live current Action is being replaced (supersede-and-
  ///   promote), so the columns are that retiring Action's D1 mirror. Overwrite
  ///   with the promoted row's own values, NULL included (D4); inheriting would
  ///   resurface the replaced Action's estimate against its successor.
  Future<void> _promoteRow(
    Action row,
    DateTime ts, {
    required bool seedFromDraft,
  }) async {
    var energyLevel = row.energyLevel;
    var timeEstimate = row.timeEstimate;
    if (seedFromDraft) {
      final seeded = await _seedMetadataFromDraft(
        row.outcomeId,
        energyLevel: energyLevel,
        timeEstimate: timeEstimate,
      );
      energyLevel = seeded.energyLevel;
      timeEstimate = seeded.timeEstimate;
    }
    // Only write the Action's effort when seeding actually changed it, so a
    // plain overwrite promote (or a seed that found no draft) leaves the row's
    // stored values — and its captured op — untouched.
    final energyDiffers = energyLevel != row.energyLevel;
    final timeDiffers = timeEstimate != row.timeEstimate;
    await (update(actions)..where((a) => a.id.equals(row.id))).write(
      ActionsCompanion(
        role: const Value('current'),
        position: const Value(null),
        energyLevel:
            energyDiffers ? Value(energyLevel) : const Value.absent(),
        timeEstimate:
            timeDiffers ? Value(timeEstimate) : const Value.absent(),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(row.id, {
      'role': 'current',
      'position': null,
      if (energyDiffers) 'energy_level': energyLevel,
      if (timeDiffers) 'time_estimate': timeEstimate,
      'updated_at': encodeInstant(ts),
    });
    await (update(todos)..where((t) => t.id.equals(row.outcomeId))).write(
      TodosCompanion(
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        updatedAt: Value(ts),
      ),
    );
    _captureOutcome(row.outcomeId, {
      'energy_level': energyLevel,
      'time_estimate': timeEstimate,
      'updated_at': encodeInstant(ts),
    });
  }

  /// The single surviving `current` Action for [outcomeId], converging an
  /// accidental multi-current set first.
  ///
  /// The 0..1-current invariant is app-enforced (no partial unique index — see
  /// `action_routes.py`), so a cross-device race can sync in two `current`
  /// rows. Any primitive that touches the current Action converges first: keep
  /// the winner by greatest `COALESCE(updated_at, created_at)`, tie-break
  /// smallest `id`; retire the rest. The rule is deterministic, so every device
  /// converges on the same winner. Convergence is repair, not clarification —
  /// it never stamps.
  Future<({Action? current, bool converged})> _resolveCurrentAction(
    String outcomeId,
    DateTime ts,
  ) async {
    final currents = await _currentActionsFor(outcomeId);
    if (currents.isEmpty) return (current: null, converged: false);
    if (currents.length == 1) return (current: currents.first, converged: false);

    final ordered = [...currents]..sort(_winnerFirst);
    final winner = ordered.first;
    for (final loser in ordered.skip(1)) {
      await _retire(loser.id, ts);
    }
    return (current: winner, converged: true);
  }

  /// Orders current rows winner-first: greatest `COALESCE(updated_at,
  /// created_at)`, tie-break smallest id.
  static int _winnerFirst(Action a, Action b) {
    final at = a.updatedAt ?? a.createdAt;
    final bt = b.updatedAt ?? b.createdAt;
    final byTime = bt.compareTo(at); // descending: greatest first
    if (byTime != 0) return byTime;
    return a.id.compareTo(b.id); // ascending: smallest id first
  }

  /// Inserts a fresh `current` Action and returns its generated id (the id lets
  /// a supersede reopen a continuation TimeLog against the successor — #476).
  Future<String> _insertCurrentAction(
    String outcomeId,
    String text, {
    String? energyLevel,
    int? timeEstimate,
    required DateTime ts,
  }) async {
    final userId = await _userIdForOutcome(outcomeId);
    final id = uuid.v4();
    await into(actions).insert(
      ActionsCompanion(
        id: Value(id),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(text),
        role: const Value('current'),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(id, {
      'outcome_id': outcomeId,
      'user_id': userId,
      'text': text,
      'role': 'current',
      'position': null,
      'energy_level': energyLevel,
      'time_estimate': timeEstimate,
      'created_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
      'done_at': null,
    });
    return id;
  }

  /// Close every open TimeLog attributed to [actionId] at [ts], returning the
  /// most-recently-started row that was closed (or null when none was open) so
  /// a supersede can reopen a continuation against the successor Action.
  ///
  /// Scoped to `action_id` — a stint the user already switched away from (open
  /// against a *different* Action) is left untouched. All-open closure is
  /// defensive against a stale multi-open edge; the invariant is one globally.
  Future<TimeLog?> _closeOpenLogFor(String actionId, DateTime ts) async {
    final open = await (select(timeLogs)
          ..where((t) => t.actionId.equals(actionId) & t.endedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
        .get();
    if (open.isEmpty) return null;
    await (update(timeLogs)
          ..where((t) => t.actionId.equals(actionId) & t.endedAt.isNull()))
        .write(TimeLogsCompanion(endedAt: Value(ts.toIso8601String())));
    for (final row in open) {
      TimeLogDao.captureLogClosedOn(attachedDatabase, row.id, ts);
    }
    // A Sprint never outlives its TimeLog (issue #910).
    await SprintDao.closeRunningSprintsOfLogs(attachedDatabase, ts, open);
    return open.first;
  }

  /// Reopen a continuation TimeLog against [newActionId], copying the closed
  /// row's `task_id`, `user_id` and `focus_session_id` so engagement continuity
  /// (and session attribution) is preserved with zero seconds lost — the
  /// close-and-reopen rule (CONTEXT.md § Switching Actions).
  Future<void> _reopenLogAgainst({
    required TimeLog closed,
    required String newActionId,
    required DateTime ts,
  }) async {
    final id = uuid.v4();
    await into(timeLogs).insert(
      TimeLogsCompanion(
        id: Value(id),
        userId: Value(closed.userId),
        taskId: Value(closed.taskId),
        actionId: Value(newActionId),
        startedAt: Value(ts.toIso8601String()),
        endedAt: const Value(null),
        focusSessionId: Value(closed.focusSessionId),
      ),
    );
    TimeLogDao.captureLogOpened(
      attachedDatabase,
      id: id,
      userId: closed.userId,
      taskId: closed.taskId,
      actionId: newActionId,
      startedAtIso: ts.toIso8601String(),
      focusSessionId: closed.focusSessionId,
    );
  }

  /// Flip a row to `role='superseded'` with `updated_at = ts` — no linkage
  /// columns.
  Future<void> _retire(String actionId, DateTime ts) async {
    await (update(actions)..where((a) => a.id.equals(actionId))).write(
      ActionsCompanion(
        role: const Value('superseded'),
        updatedAt: Value(ts),
      ),
    );
    _captureAction(actionId, {
      'role': 'superseded',
      'updated_at': encodeInstant(ts),
    });
  }

  /// The stamping rule, encoded once: an Action mutation is a clarifying
  /// micro-act, so it moves `last_clarified_at` (CONTEXT.md § Clarification).
  Future<void> _stampOutcome(String outcomeId, DateTime ts) async {
    await (update(todos)..where((t) => t.id.equals(outcomeId))).write(
      TodosCompanion(
        lastClarifiedAt: Value(ts),
        updatedAt: Value(ts),
      ),
    );
    _captureOutcome(outcomeId, {
      'last_clarified_at': encodeInstant(ts),
      'updated_at': encodeInstant(ts),
    });
  }

  Future<String> _userIdForOutcome(String outcomeId) async {
    final row = await (select(todos)..where((t) => t.id.equals(outcomeId)))
        .getSingle();
    return row.userId;
  }
}
