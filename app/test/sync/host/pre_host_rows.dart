/// One domain row in every collection that has a sync codec, written the way a
/// device that predates the sync host holds them: straight into the domain
/// store, with no outbox entry and nothing in merge state.
library;

import 'package:drift/drift.dart' show Variable;
import 'package:jeeves/database/daos/capture_dao.dart'
    show captureOutcomeIdFor, captureTagIdFor;
import 'package:jeeves/database/daos/focus_session_dao.dart'
    show
        focusSessionDispositionIdFor,
        focusSessionPlanningBypassIdFor,
        focusSessionRescheduleIdFor;
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/ids.dart'
    show focusSessionTaskIdFor, preferenceEntityId, userPreferencesWorkspaceId;

const String preHostUserId = 'pre-host-user';
const String preHostOutcomeId = '5b4c3d2e-1f0a-4b9c-8d7e-6f5a4b3c2d1e';
const String preHostPreferenceKey = 'pre_host_density';
const String preHostPreferenceValue = '"compact"';

const String _tagId = 'pre-host-tag';
const String _captureId = 'pre-host-capture';
const String _sessionId = 'pre-host-session';
const String _instant = '2026-01-01T00:00:00.000Z';

/// The entity id each collection's row becomes in merge state.
Map<String, String> get preHostEntityIdByCollection => {
      todosCollection: preHostOutcomeId,
      actionsCollection: 'pre-host-action',
      tagsCollection: _tagId,
      capturesCollection: _captureId,
      timeLogsCollection: 'pre-host-time-log',
      focusSessionsCollection: _sessionId,
      todoTagsCollection: todoTagIdFor(preHostOutcomeId, _tagId),
      captureOutcomesCollection:
          captureOutcomeIdFor(_captureId, preHostOutcomeId),
      captureTagsCollection: captureTagIdFor(_captureId, _tagId),
      focusSessionTasksCollection:
          focusSessionTaskIdFor(_sessionId, preHostOutcomeId),
      focusSessionDispositionsCollection:
          focusSessionDispositionIdFor(_sessionId, preHostOutcomeId),
      focusSessionPlanningBypassesCollection:
          focusSessionPlanningBypassIdFor(_sessionId, preHostOutcomeId),
      focusSessionReschedulesCollection:
          focusSessionRescheduleIdFor(_sessionId, preHostOutcomeId),
      outcomeBypassDecisionsCollection: 'pre-host-decision',
      userPreferencesCollection: preferenceEntityId(
          userPreferencesWorkspaceId(preHostUserId), preHostPreferenceKey),
    };

/// Write the rows. [preferenceValueJson] lets a test choose the preference.
Future<void> writeRowInEveryCollection(
  GtdDatabase domain, {
  String preferenceValueJson = preHostPreferenceValue,
}) async {
  final ids = preHostEntityIdByCollection;
  Future<void> run(String sql, List<Object?> variables) =>
      domain.customInsert(sql, variables: [
        for (final value in variables) _variable(value),
      ]);

  await run(
    "INSERT INTO todos (id, title, user_id, created_at, intent) "
    "VALUES (?, 'Old outcome', ?, ?, 'next')",
    [preHostOutcomeId, preHostUserId, _instant],
  );
  await run(
    "INSERT INTO actions (id, outcome_id, user_id, text, role, created_at) "
    "VALUES (?, ?, ?, 'Old action', 'current', ?)",
    [ids[actionsCollection], preHostOutcomeId, preHostUserId, _instant],
  );
  await run(
    "INSERT INTO tags (id, name, type, user_id) VALUES (?, 'home', 'context', ?)",
    [_tagId, preHostUserId],
  );
  await run(
    "INSERT INTO captures (id, title, user_id, created_at) "
    "VALUES (?, 'Old capture', ?, ?)",
    [_captureId, preHostUserId, _instant],
  );
  await run(
    "INSERT INTO focus_sessions (id, user_id, started_at) "
    "VALUES (?, ?, '2026-01-01T00:00:00.000Z')",
    [_sessionId, preHostUserId],
  );
  await run(
    "INSERT INTO time_logs (id, user_id, task_id, started_at) "
    "VALUES (?, ?, ?, '2026-01-01T00:00:00.000Z')",
    [ids[timeLogsCollection], preHostUserId, preHostOutcomeId],
  );
  await run(
    "INSERT INTO todo_tags (id, todo_id, tag_id, user_id) VALUES (?, ?, ?, ?)",
    [ids[todoTagsCollection], preHostOutcomeId, _tagId, preHostUserId],
  );
  await run(
    "INSERT INTO capture_outcomes (id, capture_id, outcome_id, created_at, user_id) "
    "VALUES (?, ?, ?, ?, ?)",
    [
      ids[captureOutcomesCollection],
      _captureId,
      preHostOutcomeId,
      _instant,
      preHostUserId,
    ],
  );
  await run(
    "INSERT INTO capture_tags (id, capture_id, tag_id, user_id) VALUES (?, ?, ?, ?)",
    [ids[captureTagsCollection], _captureId, _tagId, preHostUserId],
  );
  await run(
    "INSERT INTO focus_session_tasks (id, focus_session_id, task_id, position, user_id) "
    "VALUES (?, ?, ?, 0, ?)",
    [
      ids[focusSessionTasksCollection],
      _sessionId,
      preHostOutcomeId,
      preHostUserId,
    ],
  );
  await run(
    "INSERT INTO focus_session_dispositions (id, focus_session_id, task_id, disposition, user_id) "
    "VALUES (?, ?, ?, 'leave', ?)",
    [
      ids[focusSessionDispositionsCollection],
      _sessionId,
      preHostOutcomeId,
      preHostUserId,
    ],
  );
  await run(
    "INSERT INTO focus_session_planning_bypasses (id, focus_session_id, task_id, recorded_at, user_id) "
    "VALUES (?, ?, ?, ?, ?)",
    [
      ids[focusSessionPlanningBypassesCollection],
      _sessionId,
      preHostOutcomeId,
      _instant,
      preHostUserId,
    ],
  );
  await run(
    "INSERT INTO focus_session_reschedules (id, focus_session_id, task_id, recorded_at, user_id) "
    "VALUES (?, ?, ?, ?, ?)",
    [
      ids[focusSessionReschedulesCollection],
      _sessionId,
      preHostOutcomeId,
      _instant,
      preHostUserId,
    ],
  );
  await run(
    "INSERT INTO outcome_bypass_decisions (id, task_id, decision, decided_at, user_id) "
    "VALUES (?, ?, 'maybe', ?, ?)",
    [
      ids[outcomeBypassDecisionsCollection],
      preHostOutcomeId,
      _instant,
      preHostUserId,
    ],
  );
  await run(
    'INSERT INTO user_preferences (id, user_id, "key", value, updated_at) '
    "VALUES (?, ?, ?, ?, '2026-03-01T00:00:00.000Z')",
    [
      ids[userPreferencesCollection],
      preHostUserId,
      preHostPreferenceKey,
      preferenceValueJson,
    ],
  );
}

Variable<Object> _variable(Object? value) => value is int
    ? Variable<int>(value)
    : Variable<String>(value! as String);
