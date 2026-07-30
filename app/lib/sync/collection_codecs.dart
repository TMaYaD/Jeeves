/// Per-collection column↔field codecs, and the one canonical value encoding.
///
/// Twelve collections, named exactly after their tables. A codec answers two
/// questions: which columns travel on the wire for this collection, and how a
/// reduced field map becomes a row in the domain store.
///
/// ## Value encodings (protocol surface)
///
/// Byte-identical convergence makes these encodings part of the protocol — the
/// initial upload reuses these codecs, so it cannot emit anything else.
///
/// * **Drift `dateTime` columns** encode as an ISO-8601 UTC instant with
///   sub-millisecond precision **truncated** (never rounded), always exactly
///   three fractional digits, trailing `Z`: `2026-07-28T05:12:03.042Z`. Not raw
///   [DateTime.toIso8601String], whose fractional width varies with microsecond
///   content — two devices formatting the same instant must produce the same
///   bytes. The corollary is that sub-millisecond precision is not carried: an
///   author whose local row held microseconds sees them truncated once the
///   value round-trips through the log.
/// * **TEXT timestamp columns pass through.** `todos.done_at`,
///   `time_logs.started_at` / `ended_at`, `focus_sessions.started_at` /
///   `ended_at` and `user_preferences.updated_at` are declared TEXT; their raw
///   stored strings travel as opaque JSON strings, byte for byte. The codec
///   neither parses nor normalises them, so the truncation rule above governs
///   `dateTime` columns *only*.
/// * **Text, int, bool and null pass through** as JSON natives.
///
/// ## `todos.time_spent_minutes` is unsynced, not unwritten
///
/// It is a dead denormalised cache: nothing has written it since the
/// `transitionState` recompute was retired, and time-spent is derived from
/// `SUM(time_logs)` at read time with open logs valued at `now()` (#480).
/// Capture never emits it and the reducer never sees it — recomputing it would
/// buy nondeterminism (the open-log-at-`now()` term) for a column nothing
/// reads.
///
/// It is nonetheless declared **NOT NULL**, so a projected row still has to
/// carry a value or a plain `select(todos)` row read throws on the null. That
/// is what [CollectionCodec.unsyncedInsertDefaults] is for: the projector
/// supplies the column's declared default when it *creates* a row, and never
/// touches it again. The value is not a merge input, it is excluded from every
/// cross-device equality assertion. Retiring it is now an ordinary `onUpgrade`
/// step on the Drift-owned store (ADR-0035) and nothing gates it — see ADR-0030.
///
/// ## The tolerant timestamp grammar
///
/// [parseTimestampUtcMs] is the *reading* half of the instant encoding, and it
/// lives here for the same reason [encodeInstant] does: it is protocol surface.
/// [encodeInstant] answers "what does a Drift `dateTime` become on the wire";
/// this answers "which stored strings are the same instant as that". The
/// initial upload needs it because a store written before the encoding existed
/// holds microsecond-bearing and offset-bearing strings that must map onto the
/// millisecond-truncated wire value rather than being refused. [rawAsText] is
/// the one spelling for a value a column kind refused, so a report names the
/// offending value the same way wherever it is produced.
///
/// The grammar is deliberately wider than what [encodeInstant] emits, and stays
/// that way: a store written under one spelling must still be read under
/// another. It used to be pinned by golden vectors shared with a server-side
/// serialiser; both retired with the mirrored schema (#556), so this function is
/// now the single definition. Widening it is a protocol decision — every peer
/// reading a value this accepts has to accept it too.
library;

/// The twelve collections this slice carries, named after their tables.
const String todosCollection = 'todos';
const String actionsCollection = 'actions';
const String tagsCollection = 'tags';
const String capturesCollection = 'captures';
const String timeLogsCollection = 'time_logs';
const String focusSessionsCollection = 'focus_sessions';
const String todoTagsCollection = 'todo_tags';
const String captureOutcomesCollection = 'capture_outcomes';
const String captureTagsCollection = 'capture_tags';
const String focusSessionTasksCollection = 'focus_session_tasks';
const String focusSessionDispositionsCollection = 'focus_session_dispositions';
const String userPreferencesCollection = 'user_preferences';

/// How a column's SQL value maps to and from its JSON field value.
enum FieldKind {
  /// Pass-through string — including the TEXT timestamp columns.
  text,
  integer,
  boolean,

  /// Drift `dateTime`: canonical ISO-8601 UTC, three fractional digits, `Z`.
  instant,
}

/// The canonical wire form of a Drift `dateTime` value.
///
/// Truncates rather than rounds so the encoding is a pure function of the
/// millisecond floor: rounding would make two neighbouring instants collide or
/// diverge depending on their microsecond tail.
String? encodeInstant(DateTime? value) {
  if (value == null) return null;
  final utc = value.toUtc();
  final millis = utc.millisecondsSinceEpoch; // floor: microseconds discarded
  final truncated = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  final year = truncated.year.toString().padLeft(4, '0');
  final month = truncated.month.toString().padLeft(2, '0');
  final day = truncated.day.toString().padLeft(2, '0');
  final hour = truncated.hour.toString().padLeft(2, '0');
  final minute = truncated.minute.toString().padLeft(2, '0');
  final second = truncated.second.toString().padLeft(2, '0');
  final ms = truncated.millisecond.toString().padLeft(3, '0');
  return '$year-$month-${day}T$hour:$minute:$second.${ms}Z';
}

/// The inverse of [encodeInstant]; null for an absent or unparseable value.
DateTime? decodeInstant(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

// --- the tolerant timestamp grammar ---------------------------------------

/// `[ \t]` rather than `\s`: Dart's and Python's regex engines disagree about
/// which exotic code points `\s` covers, and a grammar the two sides read
/// differently is exactly the divergence the frozen spec exists to prevent.
final RegExp timestampPattern = RegExp(
  r'^[ \t]*(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})'
  r'(?::(\d{2})(?:\.(\d+))?)?[ \t]*(Z|z|[+-]\d{2}(?::?\d{2})?)?[ \t]*$',
);

/// Signed minutes east of UTC, or null when the offset is out of range.
int? _offsetMinutes(String? raw) {
  if (raw == null || raw == 'Z' || raw == 'z') return 0;
  final sign = raw.startsWith('-') ? -1 : 1;
  final digits = raw.substring(1).replaceAll(':', '');
  final hours = int.parse(digits.substring(0, 2));
  final minutes = digits.length > 2 ? int.parse(digits.substring(2, 4)) : 0;
  if (hours > 23 || minutes > 59) return null;
  return sign * (hours * 60 + minutes);
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');

String? _formatInstant(DateTime moment) {
  final utc = moment.toUtc();
  // The intersection of what Dart's and Python's date types can both represent
  // and format.
  if (utc.year < 1 || utc.year > 9999) return null;
  return '${_pad(utc.year, 4)}-${_pad(utc.month, 2)}-${_pad(utc.day, 2)}'
      'T${_pad(utc.hour, 2)}:${_pad(utc.minute, 2)}:${_pad(utc.second, 2)}'
      '.${_pad(utc.millisecond, 3)}Z';
}

/// `YYYY-MM-DDTHH:MM:SS.mmmZ`, or null when the rules refuse the value.
///
/// Accepts a [DateTime] — Dart has no zone-less value, so one carrying local
/// time is converted with `toUtc()` rather than reinterpreted — or a string
/// under the tolerant grammar frozen in the spec, where a zone-less string *is*
/// read as UTC. The instant truncates, never rounds, to millisecond precision:
/// milliseconds are the client-authorship grain, and a server-minted microsecond
/// value reaches the device carrying the same microseconds, so both sides
/// truncate identically.
String? parseTimestampUtcMs(Object? value) {
  if (value is DateTime) return _formatInstant(value);
  if (value is! String) return null;

  final match = timestampPattern.firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = match.group(6) == null ? 0 : int.parse(match.group(6)!);
  final fraction = match.group(7) ?? '';
  final millis =
      fraction.isEmpty ? 0 : int.parse('${fraction}000'.substring(0, 3));
  if (month < 1 || month > 12 || day < 1) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  final offset = _offsetMinutes(match.group(8));
  if (offset == null) return null;

  // DateTime.utc normalises out-of-range components (Feb 30 becomes Mar 2), so
  // the round-trip check below is what rejects an impossible date.
  final base = DateTime.utc(year, month, day, hour, minute, second, millis);
  if (base.year != year || base.month != month || base.day != day) return null;
  return _formatInstant(base.subtract(Duration(minutes: offset)));
}

/// One shared spelling for a value a column kind refused (the spec's
/// `raw_as_text`), so every report names the offending value identically.
String rawAsText(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isFinite && value == value.roundToDouble()) {
      return '${value.toInt()}';
    }
    // Deliberately not formatted: shortest-round-trip float formatting is not
    // guaranteed identical across the two languages.
    return '<number>';
  }
  if (value is String) return value;
  return '<unknown>';
}

/// One collection's column contract.
class CollectionCodec {
  const CollectionCodec({
    required this.collection,
    required this.table,
    required this.columns,
    required this.requiredColumns,
    required this.identityColumns,
    this.unsyncedInsertDefaults = const <String, Object?>{},
  });

  /// Collection name; also the domain table name.
  final String collection;

  /// The domain table the projector writes.
  final String table;

  /// Every synced column except `id`, which is always the entity id.
  final Map<String, FieldKind> columns;

  /// Columns a row cannot be inserted without. An entity whose live fields do
  /// not yet satisfy these is **held back**, not errored: out-of-causal-order
  /// arrival is routine, and reduced state converges.
  final Set<String> requiredColumns;

  /// How the projector locates the row this entity already occupies. `id` for
  /// owned entities; the domain pair for junctions and for the KV collection,
  /// whose `id` column is the sync row identifier rather than the domain key —
  /// which is what lets a `focus_session_tasks.id` or `user_preferences.id` a
  /// pre-#550 device minted at random be realigned onto its derivation.
  final List<String> identityColumns;

  /// Columns the op log never carries, whose declared NOT NULL the projector
  /// still has to satisfy when it **creates** a row.
  ///
  /// Applied on INSERT only, never on UPDATE: the value is not a merge input,
  /// so it must never overwrite what a local row already holds — a device that
  /// authored the row keeps whatever it had. The only member is
  /// `todos.time_spent_minutes` (see the library doc); without it a projected
  /// row would leave the column null on a store whose backing table imposes no
  /// default, and the next plain `select(todos)` read would throw.
  final Map<String, Object?> unsyncedInsertDefaults;

  bool get identifiedById =>
      identityColumns.length == 1 && identityColumns.single == 'id';
}

const Map<String, FieldKind> _junctionUserId = {'user_id': FieldKind.text};

/// Every collection's codec, keyed by collection name.
const Map<String, CollectionCodec> collectionCodecs = {
  todosCollection: CollectionCodec(
    collection: todosCollection,
    table: 'todos',
    columns: {
      'title': FieldKind.text,
      'notes': FieldKind.text,
      'priority': FieldKind.integer,
      'due_date': FieldKind.instant,
      'created_at': FieldKind.instant,
      'updated_at': FieldKind.instant,
      // Declared TEXT on the table, so it passes through opaque.
      'done_at': FieldKind.text,
      'clarified': FieldKind.boolean,
      'intent': FieldKind.text,
      'time_estimate': FieldKind.integer,
      'energy_level': FieldKind.text,
      'capture_source': FieldKind.text,
      'location_id': FieldKind.text,
      'user_id': FieldKind.text,
      'last_clarified_at': FieldKind.instant,
      'last_next_action_completion_at': FieldKind.instant,
    },
    requiredColumns: {'title', 'created_at', 'user_id'},
    identityColumns: ['id'],
    // Never on the wire, but NOT NULL on the row.
    unsyncedInsertDefaults: {'time_spent_minutes': 0},
  ),
  actionsCollection: CollectionCodec(
    collection: actionsCollection,
    table: 'actions',
    columns: {
      'outcome_id': FieldKind.text,
      'user_id': FieldKind.text,
      'text': FieldKind.text,
      'role': FieldKind.text,
      'position': FieldKind.integer,
      'energy_level': FieldKind.text,
      'time_estimate': FieldKind.integer,
      'created_at': FieldKind.instant,
      'updated_at': FieldKind.instant,
      'done_at': FieldKind.instant,
    },
    requiredColumns: {'outcome_id', 'user_id', 'text', 'role', 'created_at'},
    identityColumns: ['id'],
  ),
  tagsCollection: CollectionCodec(
    collection: tagsCollection,
    table: 'tags',
    columns: {
      'name': FieldKind.text,
      'color': FieldKind.text,
      'type': FieldKind.text,
      'user_id': FieldKind.text,
    },
    requiredColumns: {'name', 'type', 'user_id'},
    identityColumns: ['id'],
  ),
  capturesCollection: CollectionCodec(
    collection: capturesCollection,
    table: 'captures',
    columns: {
      'title': FieldKind.text,
      'notes': FieldKind.text,
      'capture_source': FieldKind.text,
      'created_at': FieldKind.instant,
      'clarified_at': FieldKind.instant,
      'updated_at': FieldKind.instant,
      'user_id': FieldKind.text,
    },
    requiredColumns: {'title', 'created_at', 'user_id'},
    identityColumns: ['id'],
  ),
  timeLogsCollection: CollectionCodec(
    collection: timeLogsCollection,
    table: 'time_logs',
    columns: {
      'user_id': FieldKind.text,
      'task_id': FieldKind.text,
      'action_id': FieldKind.text,
      // TEXT columns: opaque pass-through, never parsed.
      'started_at': FieldKind.text,
      'ended_at': FieldKind.text,
      'focus_session_id': FieldKind.text,
    },
    requiredColumns: {'user_id', 'task_id', 'started_at'},
    identityColumns: ['id'],
  ),
  focusSessionsCollection: CollectionCodec(
    collection: focusSessionsCollection,
    table: 'focus_sessions',
    columns: {
      'user_id': FieldKind.text,
      'started_at': FieldKind.text,
      'ended_at': FieldKind.text,
      'current_task_id': FieldKind.text,
    },
    requiredColumns: {'user_id', 'started_at'},
    identityColumns: ['id'],
  ),
  todoTagsCollection: CollectionCodec(
    collection: todoTagsCollection,
    table: 'todo_tags',
    columns: {
      'todo_id': FieldKind.text,
      'tag_id': FieldKind.text,
      ..._junctionUserId,
    },
    requiredColumns: {'todo_id', 'tag_id', 'user_id'},
    identityColumns: ['todo_id', 'tag_id'],
  ),
  captureOutcomesCollection: CollectionCodec(
    collection: captureOutcomesCollection,
    table: 'capture_outcomes',
    columns: {
      'capture_id': FieldKind.text,
      'outcome_id': FieldKind.text,
      'created_at': FieldKind.instant,
      ..._junctionUserId,
    },
    requiredColumns: {'capture_id', 'outcome_id', 'created_at', 'user_id'},
    identityColumns: ['capture_id', 'outcome_id'],
  ),
  captureTagsCollection: CollectionCodec(
    collection: captureTagsCollection,
    table: 'capture_tags',
    columns: {
      'capture_id': FieldKind.text,
      'tag_id': FieldKind.text,
      ..._junctionUserId,
    },
    requiredColumns: {'capture_id', 'tag_id', 'user_id'},
    identityColumns: ['capture_id', 'tag_id'],
  ),
  focusSessionTasksCollection: CollectionCodec(
    collection: focusSessionTasksCollection,
    table: 'focus_session_tasks',
    columns: {
      'focus_session_id': FieldKind.text,
      'task_id': FieldKind.text,
      'position': FieldKind.integer,
      'disposition': FieldKind.text,
      ..._junctionUserId,
    },
    requiredColumns: {'focus_session_id', 'task_id', 'position', 'user_id'},
    identityColumns: ['focus_session_id', 'task_id'],
  ),
  focusSessionDispositionsCollection: CollectionCodec(
    collection: focusSessionDispositionsCollection,
    table: 'focus_session_dispositions',
    columns: {
      'focus_session_id': FieldKind.text,
      'task_id': FieldKind.text,
      'disposition': FieldKind.text,
      ..._junctionUserId,
    },
    requiredColumns: {'focus_session_id', 'task_id', 'user_id'},
    identityColumns: ['focus_session_id', 'task_id'],
  ),
  // The KV collection. Its entity id is `preferenceEntityId(workspace, key)`
  // (the shipped KV policy), and its `value` field is the one the ADR-0011
  // Conflict Strategy registry arbitrates. Identity is the domain key
  // `(user_id, key)` rather than `id`: the DAO now mints the row under the
  // derivation, and locating by the domain key is what still realigns a row a
  // pre-#550 device created at random — the same correction it applies to
  // `focus_session_tasks.id`.
  userPreferencesCollection: CollectionCodec(
    collection: userPreferencesCollection,
    table: 'user_preferences',
    columns: {
      'user_id': FieldKind.text,
      'key': FieldKind.text,
      'value': FieldKind.text,
      'updated_at': FieldKind.text,
    },
    requiredColumns: {'user_id', 'key', 'updated_at'},
    identityColumns: ['user_id', 'key'],
  ),
};
