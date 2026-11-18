import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/autoflow.dart';
import '../../models/calendar_day.dart';
import '../../models/day_timeline.dart';
import '../../providers/calendar_timeline_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/day_timeline_provider.dart';
import '../../providers/shutdown_settings_provider.dart';
import '../../services/calendar/calendar_types.dart';
import '../capacity_bar.dart';
import 'set_time_sheet.dart';

/// Today's Plan on a day timeline: a capacity bar, one tile per piece of each
/// Plan entry at its suggested time, the lane of Sprints done at the tiles'
/// right edge, and the "Not wholly placed" tray for entries Autoflow could not
/// wholly place.
///
/// The widget owns no stored data. Its caller supplies the entries, the flow
/// origin and the typed available minutes, the Sprints done ([sprintMarks]),
/// and receives the one thing the user can change: a time they set (or clear)
/// for an entry, through [onSetPinnedStart].
///
/// When a calendar is connected the widget reads today's events itself
/// ([calendarTimelineProvider]), draws them, lays the Plan out around them, and
/// ends the day at the Evening Shutdown time instead of using the typed minutes.
/// The events live in memory only; see that provider.
class DayTimeline extends ConsumerStatefulWidget {
  const DayTimeline({
    super.key,
    required this.scope,
    required this.entries,
    required this.flowOrigin,
    required this.availableMinutes,
    required this.chunkUnitMinutes,
    required this.onSetPinnedStart,
    this.events = const [],
    this.sprintMarks = const [],
  });

  /// What the layout belongs to: the planning draft, or one session. A layout
  /// remembered for another scope is not reused.
  final String scope;
  final List<DayTimelineEntry> entries;

  /// Nothing new is placed before this; the day window starts here.
  final DateTime flowOrigin;
  final int availableMinutes;

  /// One sprint plus its short break.
  final int chunkUnitMinutes;

  /// Called with the time the user chose, or null for "Let Jeeves move it".
  final Future<void> Function(String outcomeId, DateTime? startAt)
      onSetPinnedStart;
  final List<BusyInterval> events;

  /// The Sprints done, read from the Sprint record (#910). Each is drawn in
  /// the lane at the tile's right edge, at its real time, and counted in the
  /// tile it ran on.
  final List<TileSprintMark> sprintMarks;

  @override
  ConsumerState<DayTimeline> createState() => _DayTimelineState();
}

enum _TileState { upcoming, running, done, notStarted }

/// One suggested time that a re-flow moved, with where it was.
class _Move {
  const _Move(this.outcomeId, this.previousStart);
  final String outcomeId;
  final DateTime previousStart;
}

class _DayTimelineState extends ConsumerState<DayTimeline>
    with WidgetsBindingObserver {
  static const _pixelsPerMinute = 1.0;
  static const _gutterWidth = 56.0;
  static const _minTileHeight = 24.0;

  /// The lane at the tiles' right edge, where the Sprints done are drawn at
  /// their real times.
  static const _laneWidth = 14.0;

  /// The timeline scrolls inside this height, so a long day does not push the
  /// Plan's own rows far down the page.
  static const _viewportHeight = 320.0;

  final _stackKey = GlobalKey();
  late DayLayout _layout;
  bool _layoutReady = false;
  List<BusyInterval> _previousEvents = const [];
  late String _inputsSignature;
  late String _sprintsSignature;
  late DateTime _windowStart;
  late DateTime _windowEnd;
  late final ScrollController _scrollController;

  /// The events that block time and the day length actually used: the
  /// calendar's when one is connected, the typed minutes otherwise.
  List<BusyInterval> _events = const [];
  List<CalendarEvent> _calendarEvents = const [];
  int _availableMinutes = 0;
  bool _eventsChanged = false;
  bool _calendarWasReady = false;

  /// What the last re-flow did to suggested times, until the user answers.
  List<_Move> _moves = const [];
  List<String> _conflictedPinnedIds = const [];
  Timer? _rereadTimer;

  static const _rereadInterval = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyCalendar(initial: true);
    _inputsSignature = _signatureOf();
    _sprintsSignature = _sprintsSignatureOf(widget);
    _recompute();
    _startCalendarReads();
    // Open on the now line, or on the start of the day when it is not in view.
    final now = ref.read(clockProvider)();
    final nowOffset = now.difference(_windowStart).inMinutes * _pixelsPerMinute;
    _scrollController = ScrollController(
      initialScrollOffset: nowOffset > 0 ? nowOffset - 60 : 0,
    );
  }

  /// Reads the calendar when the timeline opens and every five minutes while it
  /// is visible. A no-op while the switch is off.
  void _startCalendarReads() {
    final notifier = ref.read(calendarTimelineProvider.notifier);
    notifier.refresh();
    _rereadTimer = Timer.periodic(_rereadInterval, (_) {
      if (!mounted) return;
      if (ref.read(calendarTimelineProvider).isConnected) notifier.refresh();
    });
  }

  @override
  void dispose() {
    _rereadTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Time passing re-flows nothing; resuming moves the now line and re-reads
    // the calendar.
    if (state == AppLifecycleState.resumed && mounted) {
      ref.read(calendarTimelineProvider.notifier).refresh();
      setState(() {});
    }
  }

  /// Takes the calendar and the Evening Shutdown time into account, and
  /// re-flows when an input changed. Called from [build] after it has watched
  /// both providers, so a change in either arrives here.
  void _syncInputs() {
    _applyCalendar(initial: false);
    final signature = _signatureOf();
    if (signature != _inputsSignature) {
      _inputsSignature = signature;
      _recompute();
      return;
    }
    // The Sprints done are a record of the day, not a plan: a Sprint that
    // arrives late grows the window to hold it. The planned pieces stay where
    // they are — a record never re-flows a plan.
    final sprintsSignature = _sprintsSignatureOf(widget);
    if (sprintsSignature != _sprintsSignature) {
      _sprintsSignature = sprintsSignature;
      _computeWindow();
    }
  }

  void _applyCalendar({required bool initial}) {
    final calendar = ref.read(calendarTimelineProvider);
    // The Evening Shutdown time is read only once a calendar is connected, so a
    // screen with no calendar reads no extra setting.
    final dayEnd = calendar.status == CalendarTimelineStatus.ready
        ? calendarDayEnd(
            flowOrigin: widget.flowOrigin,
            shutdownTime: ref.read(shutdownSettingsProvider).shutdownTime)
        : null;
    final minutes = dayEnd != null
        ? dayEnd.difference(widget.flowOrigin).inMinutes
        : widget.availableMinutes;
    final windowEnd = widget.flowOrigin.add(Duration(minutes: minutes));
    final events = [
      ...widget.events,
      if (calendar.status == CalendarTimelineStatus.ready)
        ...busyIntervalsWithin(calendar.events, widget.flowOrigin, windowEnd),
    ];
    final eventsKey = _eventsKey(events);
    // The first read of the day is the calendar arriving, not the calendar
    // changing: only a change after that is announced.
    final isReady = calendar.status == CalendarTimelineStatus.ready;
    _eventsChanged =
        !initial && _calendarWasReady && eventsKey != _eventsKey(_events);
    _calendarWasReady = isReady;
    _events = events;
    _calendarEvents = calendar.status == CalendarTimelineStatus.ready
        ? timedEventsWithin(calendar.events, widget.flowOrigin, windowEnd)
        : const [];
    _availableMinutes = minutes;
  }

  static String _eventsKey(List<BusyInterval> events) => [
        for (final event in events)
          '${event.start.millisecondsSinceEpoch}-${event.end.millisecondsSinceEpoch}',
      ].join(',');

  String _signatureOf() => [
        widget.scope,
        widget.flowOrigin.millisecondsSinceEpoch,
        _availableMinutes,
        widget.chunkUnitMinutes,
        for (final entry in widget.entries) entry.layoutSignature,
        _eventsKey(_events),
      ].join(';');

  void _recompute() {
    final previousStarts = {
      if (_layoutReady)
        for (final placement in _layout.entries)
          if (placement.pieces.isNotEmpty)
            placement.outcomeId: placement.pieces.first.start,
    };
    final previousConflicts = {
      if (_layoutReady)
        for (final placement in _layout.entries)
          for (final piece in placement.pieces)
            if (piece.isPinned && piece.overlapsEvent(_previousEvents))
              placement.outcomeId,
    };
    _layout = flowDay(
      scope: widget.scope,
      last: ref.read(dayTimelineLastLayoutProvider),
      now: ref.read(clockProvider)(),
      flowOrigin: widget.flowOrigin,
      availableMinutes: _availableMinutes,
      chunkUnitMinutes: widget.chunkUnitMinutes,
      entries: widget.entries,
      events: _events,
    );
    if (_eventsChanged && _layoutReady) {
      _moves = [
        for (final placement in _layout.entries)
          if (placement.pieces.isNotEmpty &&
              previousStarts[placement.outcomeId] != null &&
              !placement.pieces.first.isPinned &&
              previousStarts[placement.outcomeId] !=
                  placement.pieces.first.start)
            _Move(placement.outcomeId, previousStarts[placement.outcomeId]!),
      ];
      _conflictedPinnedIds = [
        for (final placement in _layout.entries)
          for (final piece in placement.pieces)
            if (piece.isPinned &&
                piece.overlapsEvent(_events) &&
                !previousConflicts.contains(placement.outcomeId))
              placement.outcomeId,
      ];
    }
    _layoutReady = true;
    _previousEvents = _events;
    _sprintsSignature = _sprintsSignatureOf(widget);
    _computeWindow();
  }

  /// The stretch of the day the timeline draws.
  ///
  /// The planned pieces, the available time, and the Sprints done. A Sprint is
  /// a record of what happened, not a plan: one that ran past the planned
  /// window is drawn where it ran, so the window grows to hold it. The planned
  /// placements are not moved — the window only says how much of the day is
  /// drawn.
  ///
  /// [now] is the instant the window is drawn for; a Sprint still running
  /// reaches to it, so the window moves on as the Sprint goes on.
  void _computeWindow([DateTime? now]) {
    final dayEnd =
        widget.flowOrigin.add(Duration(minutes: _availableMinutes));
    var first = widget.flowOrigin;
    var last = dayEnd;
    for (final placement in _layout.entries) {
      for (final piece in placement.pieces) {
        if (piece.start.isBefore(first)) first = piece.start;
        if (piece.end.isAfter(last)) last = piece.end;
      }
    }
    final at = now ?? ref.read(clockProvider)();
    for (final mark in _marksInLane()) {
      if (mark.startedAt.isBefore(first)) first = mark.startedAt;
      // A running Sprint has no end yet: it reaches to now.
      final end = mark.endedAt ?? at;
      if (end.isAfter(last)) last = end;
    }
    _windowStart = DateTime(first.year, first.month, first.day, first.hour);
    final endsOnTheHour = last.minute == 0 && last.second == 0;
    _windowEnd = DateTime(last.year, last.month, last.day, last.hour)
        .add(Duration(hours: endsOnTheHour ? 0 : 1));
  }

  /// The Sprints the lane draws: the day's, on the Outcomes the day carries.
  ///
  /// A Sprint from another day is not part of this day's record, and a Sprint
  /// on an Outcome the day does not carry has no tile to belong to. The window
  /// holds exactly these, so a Sprint that is not drawn does not stretch it.
  List<TileSprintMark> _marksInLane() {
    final byOutcome = tileSprintMarksOfDay(
      widget.sprintMarks,
      widget.flowOrigin,
    );
    return [
      for (final entry in widget.entries)
        for (final mark
            in byOutcome[entry.outcomeId] ?? const <TileSprintMark>[])
          mark,
    ];
  }

  /// The Sprints the lane draws, by id and time: what the window must hold.
  static String _sprintsSignatureOf(DayTimeline widget) => [
        for (final mark in widget.sprintMarks)
          '${mark.id}-${mark.startedAt.millisecondsSinceEpoch}-'
              '${mark.endedAt?.millisecondsSinceEpoch ?? 0}',
      ].join(';');

  DayTimelineEntry _entryFor(String outcomeId) =>
      widget.entries.firstWhere((entry) => entry.outcomeId == outcomeId);

  /// The free stretches for [entry]: the day window minus the events and every
  /// other entry's tiles.
  List<BusyInterval> _gapsFor(DayTimelineEntry entry) {
    final busy = <BusyInterval>[
      ..._events,
      for (final placement in _layout.entries)
        if (placement.outcomeId != entry.outcomeId)
          for (final piece in placement.pieces)
            BusyInterval(start: piece.start, end: piece.end),
    ];
    return freeGaps(widget.flowOrigin,
        widget.flowOrigin.add(Duration(minutes: _availableMinutes)), busy);
  }

  Future<void> _openSheet(DayTimelineEntry entry, {DateTime? initialStart}) async {
    final placement = _layout.entryFor(entry.outcomeId);
    final gaps = _gapsFor(entry);
    final start = initialStart ??
        (placement.pieces.isNotEmpty
            ? placement.pieces.first.start
            : (gaps.isNotEmpty ? gaps.first.start : widget.flowOrigin));
    final choice = await showSetTimeSheet(
      context,
      title: entry.title,
      estimateMinutes: entry.estimateMinutes,
      initialStart: start,
      freeGaps: gaps,
      events: _events,
      isPinned: entry.pinnedStartAt != null,
    );
    if (choice == null) return;
    await widget.onSetPinnedStart(entry.outcomeId, choice.startAt);
  }

  void _onDrop(DragTargetDetails<String> details) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final entry = _entryFor(details.data);
    final local = box.globalToLocal(details.offset);
    final droppedMinutes = (local.dy / _pixelsPerMinute).round();
    var dropped = _windowStart.add(Duration(minutes: droppedMinutes));
    dropped = DateTime(dropped.year, dropped.month, dropped.day, dropped.hour,
        (dropped.minute ~/ 5) * 5);
    for (final gap in _gapsFor(entry)) {
      final roomy =
          gap.end.difference(gap.start).inMinutes >= entry.estimateMinutes;
      if (roomy && !dropped.isBefore(gap.start) && dropped.isBefore(gap.end)) {
        dropped = gap.start;
        break;
      }
    }
    _openSheet(entry, initialStart: dropped);
  }

  String _clock(DateTime time) => MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay.fromDateTime(time));

  static String _duration(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final calendar = ref.watch(calendarTimelineProvider);
    if (calendar.status == CalendarTimelineStatus.ready) {
      ref.watch(shutdownSettingsProvider.select((s) => s.shutdownTime));
    }
    _syncInputs();
    final now = ref.read(clockProvider)();
    // The window is drawn for the instant it is drawn at: a Sprint still
    // running grows the window as it goes on, the way the now line moves.
    _computeWindow(now);
    final dayEnd =
        widget.flowOrigin.add(Duration(minutes: _availableMinutes));
    final freeMinutes = freeGaps(widget.flowOrigin, dayEnd, _events)
        .fold<int>(0, (sum, gap) => sum + gap.end.difference(gap.start).inMinutes);
    final capacity = _layout.capacity;
    final totalMinutes = _windowEnd.difference(_windowStart).inMinutes;
    final notWhollyPlaced = [
      for (final placement in _layout.entries)
        if (placement.unplacedMinutes > 0) placement,
    ];
    // The Sprints done, grouped by the Outcome they ran on. A Sprint from
    // another day is not part of this day's record.
    final sprintsByOutcome = tileSprintMarksOfDay(
      widget.sprintMarks,
      widget.flowOrigin,
    );

    return Column(
      key: const Key('day_timeline'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CapacityBar(
          realMinutes: capacity.realMinutes,
          defaultMinutes: capacity.defaultCountedMinutes,
          availableMinutes: freeMinutes,
        ),
        const SizedBox(height: 6),
        Text(
          capacity.plannedMinutes > freeMinutes
              ? '${_duration(capacity.plannedMinutes)} planned of '
                  '${_duration(freeMinutes)} free · Over by '
                  '${_duration(capacity.plannedMinutes - freeMinutes)}'
              : '${_duration(capacity.plannedMinutes)} planned of '
                  '${_duration(freeMinutes)} free',
          key: const Key('day_timeline_capacity_label'),
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        if (capacity.plannedMinutes > freeMinutes)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              "You have planned more than the time you have today. "
              "Everything stays in your Plan; consider moving something out.",
              key: const Key('day_timeline_overbooked_notice'),
              style: const TextStyle(fontSize: 13, color: Color(0xFFB45309)),
            ),
          ),
        _calendarStatus(calendar),
        _moveNotice(),
        _conflictNotice(),
        const SizedBox(height: 12),
        SizedBox(
          height: (totalMinutes * _pixelsPerMinute)
              .clamp(0.0, _viewportHeight)
              .toDouble(),
          child: SingleChildScrollView(
            controller: _scrollController,
            child: SizedBox(
              height: totalMinutes * _pixelsPerMinute,
              child: DragTarget<String>(
            onAcceptWithDetails: _onDrop,
            builder: (context, _, _) => Stack(
              key: _stackKey,
              clipBehavior: Clip.none,
              children: [
                for (var at = _windowStart;
                    at.isBefore(_windowEnd);
                    at = at.add(const Duration(hours: 1)))
                  Positioned(
                    top: at.difference(_windowStart).inMinutes *
                        _pixelsPerMinute,
                    left: 0,
                    right: _laneWidth,
                    child: Row(
                      children: [
                        SizedBox(
                          width: _gutterWidth,
                          child: Text(_clock(at),
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500])),
                        ),
                        Expanded(
                            child: Divider(
                                height: 1, color: Colors.grey[200])),
                      ],
                    ),
                  ),
                for (final event in _calendarEvents) _eventBlock(event),
                for (final placement in _layout.entries)
                  for (final piece in placement.pieces)
                    _tile(placement, piece, now, sprintsByOutcome),
                _lane(now),
                if (!now.isBefore(_windowStart) && now.isBefore(_windowEnd))
                  Positioned(
                    key: const Key('day_timeline_now_line'),
                    top: now.difference(_windowStart).inMinutes *
                        _pixelsPerMinute,
                    left: _gutterWidth - 8,
                    right: _laneWidth,
                    child: const IgnorePointer(
                      child: Divider(
                          height: 2,
                          thickness: 2,
                          color: Color(0xFF2563EB)),
                    ),
                  ),
              ],
            ),
          ),
            ),
          ),
        ),
        if (notWhollyPlaced.isNotEmpty) ...[
          const SizedBox(height: 16),
          _tray(notWhollyPlaced),
        ],
      ],
    );
  }

  /// The line under the capacity label that says what the calendar is doing.
  Widget _calendarStatus(CalendarTimelineState calendar) {
    final (text, retry) = switch (calendar.status) {
      CalendarTimelineStatus.notConnected => (
          'No calendar connected. You can show it in Settings.',
          false
        ),
      CalendarTimelineStatus.loading => ('Reading your calendar…', false),
      CalendarTimelineStatus.permissionRefused => (
          'Jeeves was not allowed to read your calendar. You can allow it in '
              'your phone\'s settings.',
          true
        ),
      CalendarTimelineStatus.unavailable => (
          'Your calendar could not be read just now.',
          true
        ),
      CalendarTimelineStatus.ready => ('', false),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('day_timeline_calendar_status'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          ),
          if (retry)
            TextButton(
              key: const Key('day_timeline_calendar_try_again'),
              onPressed: () =>
                  ref.read(calendarTimelineProvider.notifier).refresh(),
              child: const Text('Try again'),
            ),
        ],
      ),
    );
  }

  Widget _banner(Key key, String text, List<Widget> actions) => Container(
        key: key,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFBFDBFE)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: const TextStyle(fontSize: 13)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        ),
      );

  /// "I have moved two suggested times", with "Very good" and "Undo".
  Widget _moveNotice() {
    if (_moves.isEmpty) return const SizedBox.shrink();
    final count = _moves.length;
    return _banner(
      const Key('day_timeline_moved_notice'),
      count == 1
          ? 'Your calendar changed, so I have moved one suggested time.'
          : 'Your calendar changed, so I have moved $count suggested times.',
      [
        TextButton(
          key: const Key('day_timeline_moved_ok'),
          onPressed: () => setState(() => _moves = const []),
          child: const Text('Very good'),
        ),
        TextButton(
          key: const Key('day_timeline_moved_undo'),
          onPressed: _undoMoves,
          child: const Text('Undo'),
        ),
      ],
    );
  }

  /// Undo pins every moved entry at the start it had before: the one thing that
  /// can be stored, and the only meaning Undo can have.
  Future<void> _undoMoves() async {
    final moves = _moves;
    setState(() => _moves = const []);
    for (final move in moves) {
      await widget.onSetPinnedStart(move.outcomeId, move.previousStart);
    }
  }

  /// A time the user set now overlaps an event.
  Widget _conflictNotice() {
    if (_conflictedPinnedIds.isEmpty) return const SizedBox.shrink();
    final titles = [
      for (final id in _conflictedPinnedIds) _entryFor(id).title,
    ].join(', ');
    return _banner(
      const Key('day_timeline_conflict_notice'),
      'A time you set now overlaps an event in your calendar: $titles.',
      [
        TextButton(
          key: const Key('day_timeline_conflict_leave'),
          onPressed: () => setState(() => _conflictedPinnedIds = const []),
          child: const Text('Leave it'),
        ),
        TextButton(
          key: const Key('day_timeline_conflict_release'),
          onPressed: _releaseConflicted,
          child: const Text('Let Jeeves move it'),
        ),
      ],
    );
  }

  Future<void> _releaseConflicted() async {
    final ids = _conflictedPinnedIds;
    setState(() => _conflictedPinnedIds = const []);
    for (final id in ids) {
      await widget.onSetPinnedStart(id, null);
    }
  }

  /// A calendar event: hatched, and not interactive.
  Widget _eventBlock(CalendarEvent event) {
    final start = event.start.isBefore(_windowStart) ? _windowStart : event.start;
    final end = event.end.isAfter(_windowEnd) ? _windowEnd : event.end;
    final height = (end.difference(start).inMinutes * _pixelsPerMinute)
        .clamp(_minTileHeight, double.infinity)
        .toDouble();
    return Positioned(
      key: Key('day_timeline_event_${event.id}'),
      top: start.difference(_windowStart).inMinutes * _pixelsPerMinute,
      left: _gutterWidth,
      right: _laneWidth,
      height: height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: const _HatchPainter(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFD1D5DB)),
            ),
            child: Text(
              '${event.title.isEmpty ? 'Busy' : event.title} · '
              '${_clock(event.start)} – ${_clock(event.end)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(
    EntryPlacement placement,
    PlacedPiece piece,
    DateTime now,
    Map<String, List<TileSprintMark>> sprintsByOutcome,
  ) {
    final entry = _entryFor(placement.outcomeId);
    final state = entry.isDone
        ? _TileState.done
        : entry.isRunning
            ? _TileState.running
            : (piece.end.isBefore(now) && !entry.isEngaged)
                ? _TileState.notStarted
                : _TileState.upcoming;
    final (background, border, foreground) = switch (state) {
      _TileState.upcoming => (
          const Color(0xFFEFF6FF),
          const Color(0xFFBFDBFE),
          const Color(0xFF1A1A2E)
        ),
      _TileState.running => (
          const Color(0xFF2563EB),
          const Color(0xFF1D4ED8),
          Colors.white
        ),
      _TileState.done => (
          const Color(0xFFF3F4F6),
          const Color(0xFFE5E7EB),
          const Color(0xFF6B7280)
        ),
      _TileState.notStarted => (
          const Color(0xFFFEF3C7),
          const Color(0xFFF59E0B),
          const Color(0xFF1A1A2E)
        ),
    };
    final labels = <String>[
      if (placement.pieces.length > 1) 'part ${piece.part}',
      if (piece.isPinned) 'Set by you',
      switch (state) {
        _TileState.done => 'Done',
        _TileState.running => 'Running',
        _TileState.notStarted => 'Not started',
        _TileState.upcoming => '',
      },
    ].where((label) => label.isNotEmpty).toList();
    final height =
        (piece.minutes * _pixelsPerMinute).clamp(_minTileHeight, double.infinity).toDouble();
    final timeText = '${_clock(piece.start)} – ${_clock(piece.end)}';
    // The count is the Outcome's, not the piece's: it is shown once, on the
    // piece that opens the Outcome's tiles.
    final sprintCount = _sprintCount(
      piece.part == placement.pieces.first.part
          ? (sprintsByOutcome[placement.outcomeId] ?? const <TileSprintMark>[])
          : const <TileSprintMark>[],
      now,
    );
    final detail = [timeText, ...labels, ?sprintCount].join(' · ');

    final body = Container(
      key: Key('day_timeline_tile_${piece.outcomeId}_${piece.part}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          top: BorderSide(color: border),
          left: BorderSide(color: border),
          right: BorderSide(color: border),
          bottom: BorderSide(
              color: entry.isTimeboxed ? foreground : border,
              width: entry.isTimeboxed ? 4 : 1),
        ),
      ),
      child: ClipRect(
        child: height < 48
            ? Row(
                children: [
                  Expanded(
                    child: Text(entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: foreground)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      [
                        _clock(piece.start),
                        if (placement.pieces.length > 1) 'part ${piece.part}',
                      ].join(' · '),
                      style: TextStyle(fontSize: 11, color: foreground)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: foreground)),
                  Text(detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: foreground)),
                ],
              ),
      ),
    );

    return Positioned(
      top: piece.start.difference(_windowStart).inMinutes * _pixelsPerMinute,
      left: _gutterWidth,
      right: _laneWidth,
      height: height,
      child: LongPressDraggable<String>(
        data: entry.outcomeId,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 200,
            padding: const EdgeInsets.all(8),
            child: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: body),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openSheet(entry),
          child: body,
        ),
      ),
    );
  }

  /// The lane at the tiles' right edge: every Sprint done, drawn at its real
  /// time.
  ///
  /// A Sprint is drawn where it happened, so one that ran past its tile or
  /// fell short of it is not "corrected" to fit: the lane and the tile are
  /// two records of the same day, never reconciled.
  Widget _lane(DateTime now) {
    // Only the Sprints of the day's Plan entries: a Sprint on an Outcome the
    // day does not carry has no tile to belong to.
    final marks = _marksInLane();
    return Positioned(
      key: const Key('day_timeline_sprint_lane'),
      right: 0,
      top: 0,
      bottom: 0,
      width: _laneWidth,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            const Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: Color(0xFFE5E7EB)),
            ),
            for (final mark in marks)
              Positioned(
                key: Key('day_timeline_sprint_${mark.id}'),
                top: mark.startedAt.difference(_windowStart).inMinutes *
                    _pixelsPerMinute,
                height: (mark.durationMinutesAt(now) * _pixelsPerMinute)
                    .clamp(3.0, double.infinity)
                    .toDouble(),
                left: 3,
                right: 3,
                child: const ColoredBox(color: Color(0xFF2563EB)),
              ),
          ],
        ),
      ),
    );
  }

  /// "2 sprints · 54m": how many Sprints the Outcome ran and how long they
  /// took. Null when it ran none.
  static String? _sprintCount(List<TileSprintMark> marks, DateTime now) {
    if (marks.isEmpty) return null;
    final minutes = marks.fold<int>(
        0, (sum, mark) => sum + mark.durationMinutesAt(now));
    return '${marks.length} sprint${marks.length == 1 ? '' : 's'} · '
        '${_duration(minutes)}';
  }

  Widget _tray(List<EntryPlacement> placements) {
    return Container(
      key: const Key('day_timeline_tray'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Not wholly placed',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final placement in placements)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_entryFor(placement.outcomeId).title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(
                          placement.reason == UnplacedReason.outsideTimeContext
                              ? 'Its time context allows no time today.'
                              : '${_duration(placement.unplacedMinutes)} has '
                                  'no free time today.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: Key('day_timeline_tray_set_time_${placement.outcomeId}'),
                    onPressed: () => _openSheet(_entryFor(placement.outcomeId)),
                    child: const Text('Set the time'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Diagonal hatching for calendar events.
class _HatchPainter extends CustomPainter {
  const _HatchPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)));
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF3F4F6));
    final line = Paint()
      ..color = const Color(0xFFD1D5DB)
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter oldDelegate) => false;
}
