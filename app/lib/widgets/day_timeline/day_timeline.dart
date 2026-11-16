import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/autoflow.dart';
import '../../models/day_timeline.dart';
import '../../providers/clock_provider.dart';
import '../../providers/day_timeline_provider.dart';
import '../capacity_bar.dart';
import 'set_time_sheet.dart';

/// Today's Plan on a day timeline: a capacity bar, one tile per piece of each
/// Plan entry at its suggested time, and the "Not wholly placed" tray for
/// entries Autoflow could not wholly place.
///
/// The widget owns no data. Its caller supplies the entries, the flow origin and
/// the available minutes, and receives the one thing the user can change: a time
/// they set (or clear) for an entry, through [onSetPinnedStart].
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

  @override
  ConsumerState<DayTimeline> createState() => _DayTimelineState();
}

enum _TileState { upcoming, running, done, notStarted }

class _DayTimelineState extends ConsumerState<DayTimeline>
    with WidgetsBindingObserver {
  static const _pixelsPerMinute = 1.0;
  static const _gutterWidth = 56.0;
  static const _minTileHeight = 24.0;

  final _stackKey = GlobalKey();
  late DayLayout _layout;
  late String _inputsSignature;
  late DateTime _windowStart;
  late DateTime _windowEnd;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputsSignature = _signatureOf(widget);
    _recompute();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Time passing re-flows nothing; resuming only moves the now line.
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(DayTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _signatureOf(widget);
    if (signature != _inputsSignature) {
      _inputsSignature = signature;
      _recompute();
    }
  }

  static String _signatureOf(DayTimeline widget) => [
        widget.scope,
        widget.flowOrigin.millisecondsSinceEpoch,
        widget.availableMinutes,
        widget.chunkUnitMinutes,
        for (final entry in widget.entries) entry.layoutSignature,
        for (final event in widget.events)
          '${event.start.millisecondsSinceEpoch}-${event.end.millisecondsSinceEpoch}',
      ].join(';');

  void _recompute() {
    _layout = flowDay(
      scope: widget.scope,
      last: ref.read(dayTimelineLastLayoutProvider),
      now: ref.read(clockProvider)(),
      flowOrigin: widget.flowOrigin,
      availableMinutes: widget.availableMinutes,
      chunkUnitMinutes: widget.chunkUnitMinutes,
      entries: widget.entries,
      events: widget.events,
    );
    final dayEnd =
        widget.flowOrigin.add(Duration(minutes: widget.availableMinutes));
    var first = widget.flowOrigin;
    var last = dayEnd;
    for (final placement in _layout.entries) {
      for (final piece in placement.pieces) {
        if (piece.start.isBefore(first)) first = piece.start;
        if (piece.end.isAfter(last)) last = piece.end;
      }
    }
    _windowStart = DateTime(first.year, first.month, first.day, first.hour);
    final endsOnTheHour = last.minute == 0 && last.second == 0;
    _windowEnd = DateTime(last.year, last.month, last.day, last.hour)
        .add(Duration(hours: endsOnTheHour ? 0 : 1));
  }

  DayTimelineEntry _entryFor(String outcomeId) =>
      widget.entries.firstWhere((entry) => entry.outcomeId == outcomeId);

  /// The free stretches for [entry]: the day window minus the events and every
  /// other entry's tiles.
  List<BusyInterval> _gapsFor(DayTimelineEntry entry) {
    final busy = <BusyInterval>[
      ...widget.events,
      for (final placement in _layout.entries)
        if (placement.outcomeId != entry.outcomeId)
          for (final piece in placement.pieces)
            BusyInterval(start: piece.start, end: piece.end),
    ];
    return freeGaps(widget.flowOrigin,
        widget.flowOrigin.add(Duration(minutes: widget.availableMinutes)), busy);
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
      events: widget.events,
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
    final now = ref.read(clockProvider)();
    final dayEnd =
        widget.flowOrigin.add(Duration(minutes: widget.availableMinutes));
    final freeMinutes = freeGaps(widget.flowOrigin, dayEnd, widget.events)
        .fold<int>(0, (sum, gap) => sum + gap.end.difference(gap.start).inMinutes);
    final capacity = _layout.capacity;
    final totalMinutes = _windowEnd.difference(_windowStart).inMinutes;
    final notWhollyPlaced = [
      for (final placement in _layout.entries)
        if (placement.unplacedMinutes > 0) placement,
    ];

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
        const SizedBox(height: 12),
        SizedBox(
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
                    right: 0,
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
                for (final placement in _layout.entries)
                  for (final piece in placement.pieces)
                    _tile(placement, piece, now),
                if (!now.isBefore(_windowStart) && now.isBefore(_windowEnd))
                  Positioned(
                    key: const Key('day_timeline_now_line'),
                    top: now.difference(_windowStart).inMinutes *
                        _pixelsPerMinute,
                    left: _gutterWidth - 8,
                    right: 0,
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
        if (notWhollyPlaced.isNotEmpty) ...[
          const SizedBox(height: 16),
          _tray(notWhollyPlaced),
        ],
      ],
    );
  }

  Widget _tile(EntryPlacement placement, PlacedPiece piece, DateTime now) {
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
    final detail = [timeText, ...labels].join(' · ');

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
      right: 0,
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
