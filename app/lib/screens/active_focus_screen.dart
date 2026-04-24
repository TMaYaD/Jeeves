import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Expression, Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../database/gtd_database.dart' show TodosCompanion;
import '../providers/auth_provider.dart';
import '../providers/daily_planning_provider.dart';
import '../providers/database_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/sprint_timer_provider.dart';
import '../providers/task_detail_provider.dart';
import '../services/notification_service.dart';
import '../widgets/elapsed_timer_widget.dart';

class ActiveFocusScreen extends ConsumerStatefulWidget {
  const ActiveFocusScreen({super.key});

  @override
  ConsumerState<ActiveFocusScreen> createState() => _ActiveFocusScreenState();
}

class _ActiveFocusScreenState extends ConsumerState<ActiveFocusScreen>
    with WidgetsBindingObserver {
  Timer? _bgNotificationTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bgNotificationTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    super.didChangeAppLifecycleState(lifecycleState);
    final focusState = ref.read(focusModeProvider);
    if (!focusState.isActive) return;

    if (lifecycleState == AppLifecycleState.paused) {
      _onBackground(focusState);
    } else if (lifecycleState == AppLifecycleState.resumed) {
      _onForeground();
    }
  }

  void _onBackground(FocusModeState focusState) {
    final todoId = focusState.activeTodoId;
    if (todoId == null) return;
    final title =
        ref.read(taskDetailTodoProvider(todoId)).value?.title ?? 'Focus Task';
    NotificationService.instance.showFocusNotification(
      title: title,
      elapsed: focusState.elapsed,
    );
    _bgNotificationTimer?.cancel();
    _bgNotificationTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      final current = ref.read(focusModeProvider);
      final currentTitle =
          ref.read(taskDetailTodoProvider(todoId)).value?.title ?? 'Focus Task';
      NotificationService.instance.showFocusNotification(
        title: currentTitle,
        elapsed: current.elapsed,
      );
    });
  }

  void _onForeground() {
    _bgNotificationTimer?.cancel();
    _bgNotificationTimer = null;
    NotificationService.instance.cancelFocusNotification();
  }

  Future<void> _onComplete(String todoId) async {
    ref.read(sprintTimerProvider.notifier).stopSprint().ignore();
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.transitionState(todoId, userId, GtdState.done);
    ref.read(focusModeProvider.notifier).endFocus();
    if (!mounted) return;

    final allSelected = await ref.read(todaySelectedTasksProvider.future);
    if (!mounted) return;

    final nextTask = allSelected
        .where((t) =>
            t.id != todoId &&
            t.state != GtdState.done.value &&
            t.state != GtdState.inProgress.value)
        .firstOrNull;

    final message = nextTask != null
        ? 'Done! Next up: ${nextTask.title}'
        : 'All done for today!';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2667B7),
      ),
    );
    context.go('/focus');
  }

  /// Stops the sprint (logs partial time) and returns to the focus list without
  /// changing the task state — it stays in the day plan as inProgress.
  Future<void> _onStop(String todoId) async {
    await ref.read(sprintTimerProvider.notifier).stopSprint();
    ref.read(focusModeProvider.notifier).endFocus();
    if (!mounted) return;
    context.go('/focus');
  }

  Future<void> _onExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Focus Mode?'),
        content: const Text('Your sprint timer will keep running in the background.'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2667B7),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      ref.read(focusModeProvider.notifier).pauseFocus();
      context.go('/focus');
    }
  }

  @override
  Widget build(BuildContext context) {
    final focusState = ref.watch(focusModeProvider);
    final todoId = focusState.activeTodoId;

    if (todoId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/focus');
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final todoAsync = ref.watch(taskDetailTodoProvider(todoId));

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: todoAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (todo) {
            if (todo == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) context.go('/focus');
              });
              return const SizedBox.shrink();
            }
            return _FocusBody(
              todo: todo,
              onComplete: () => _onComplete(todo.id),
              onStop: () => _onStop(todo.id),
              onExit: _onExit,
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Focus body — the sprint timer IS the focus mode
// ---------------------------------------------------------------------------

class _FocusBody extends ConsumerStatefulWidget {
  const _FocusBody({
    required this.todo,
    required this.onComplete,
    required this.onStop,
    required this.onExit,
  });

  final Todo todo;
  final VoidCallback onComplete;
  final VoidCallback onStop;
  final VoidCallback onExit;

  @override
  ConsumerState<_FocusBody> createState() => _FocusBodyState();
}

class _FocusBodyState extends ConsumerState<_FocusBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pageController = PageController();

    // Sprint starts the moment focus mode starts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final timer = ref.read(sprintTimerProvider);
      if (!timer.isActive && !timer.isProcessing) {
        ref.read(sprintTimerProvider.notifier).startSprint(widget.todo);
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final timer = ref.watch(sprintTimerProvider);
    final notifier = ref.read(sprintTimerProvider.notifier);

    final isBreak = timer.isBreak;
    final ringColor =
        isBreak ? const Color(0xFF10B981) : const Color(0xFF2563EB);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: task title + exit button
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    todo.title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Exit Focus Mode',
                icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                onPressed: widget.onExit,
              ),
            ],
          ),
        ),
        // Jeeves banner — sprint and break aware
        const ElapsedTimerWidget(),
        // Carousel: sprint ring (page 0) | notes (page 1)
        Expanded(
          child: PageView(
            controller: _pageController,
            onPageChanged: (p) => setState(() => _currentPage = p),
            children: [
              _TimerPage(
                timer: timer,
                ringColor: ringColor,
                pulseCtrl: _pulseCtrl,
              ),
              _NotesPage(todo: todo),
            ],
          ),
        ),
        // Page dots
        _PageDots(current: _currentPage),
        // Action bar: pause/resume | Done | stop
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[200]!)),
          ),
          child: Row(
            children: [
              // Pause → starts break early; play during break → starts next sprint
              Expanded(
                child: OutlinedButton(
                  onPressed: timer.isProcessing
                      ? null
                      : () {
                          if (isBreak) {
                            notifier.skipBreak();
                          } else {
                            notifier.pauseSprint();
                          }
                        },
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Icon(
                    isBreak
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Done — mark task complete
              Expanded(
                child: FilledButton(
                  onPressed: widget.onComplete,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2667B7),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Done'),
                ),
              ),
              const SizedBox(width: 8),
              // Stop — keep task in plan, log partial time, return to focus list
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onStop,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red[600],
                    side: BorderSide(color: Colors.red[300]!),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Icon(Icons.stop_rounded, size: 22),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Timer page — sprint ring + dots column
// ---------------------------------------------------------------------------

class _TimerPage extends StatelessWidget {
  const _TimerPage({
    required this.timer,
    required this.ringColor,
    required this.pulseCtrl,
  });
  final SprintTimerState timer;
  final Color ringColor;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ringSize = math.min(
          constraints.maxWidth - 72.0,
          constraints.maxHeight * 0.72,
        ).clamp(160.0, 300.0);

        return Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SprintRing(
                timer: timer,
                size: ringSize,
                color: ringColor,
              ),
              const SizedBox(width: 20),
              _SprintDotsColumn(
                timer: timer,
                pulseCtrl: pulseCtrl,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Notes page — inline text editor, auto-saved to DB
// ---------------------------------------------------------------------------

class _NotesPage extends ConsumerStatefulWidget {
  const _NotesPage({required this.todo});
  final Todo todo;

  @override
  ConsumerState<_NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<_NotesPage> {
  late final TextEditingController _ctrl;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.todo.notes ?? '');
    _ctrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final text = _ctrl.text.trim();
    try {
      await (db.update(db.todos)
            ..where((t) => Expression.and(
                [t.id.equals(widget.todo.id), t.userId.equals(userId)])))
          .write(TodosCompanion(
        notes: Value(text.isEmpty ? null : text),
        updatedAt: Value(DateTime.now()),
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Notes',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF374151),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF374151),
                height: 1.6,
              ),
              decoration: const InputDecoration(
                hintText: 'Jot down ideas, links, or sub-tasks…',
                hintStyle: TextStyle(color: Color(0xFFD1D5DB)),
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Page dots indicator
// ---------------------------------------------------------------------------

class _PageDots extends StatelessWidget {
  const _PageDots({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(
          2,
          (i) => Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i == current
                  ? const Color(0xFF2563EB)
                  : const Color(0xFFD1D5DB),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sprint ring — countdown (full→empty) or overtime (empty→full, amber→red)
// ---------------------------------------------------------------------------

class _SprintRing extends StatelessWidget {
  const _SprintRing(
      {required this.timer, required this.size, required this.color});
  final SprintTimerState timer;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bool overtime = timer.isOvertime;

    final Color ringColor;
    final Color trackColor;
    final double progress;
    final Duration displayTime;

    if (overtime) {
      final p = timer.overtimeProgress;
      ringColor = Color.lerp(
            const Color(0xFFF59E0B),
            const Color(0xFFDC2626),
            p,
          ) ??
          const Color(0xFFDC2626);
      trackColor = const Color(0xFFFEF3C7);
      progress = p;
      displayTime = timer.overtime;
    } else {
      ringColor = color;
      trackColor =
          timer.isBreak ? const Color(0xFFD1FAE5) : const Color(0xFFDBEAFE);
      progress = timer.progress;
      displayTime = timer.remaining;
    }

    final minutes =
        displayTime.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        displayTime.inSeconds.remainder(60).toString().padLeft(2, '0');

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          ringColor: ringColor,
          trackColor: trackColor,
        ),
        child: Center(
          child: Text(
            '$minutes:$seconds',
            style: TextStyle(
              fontSize: size * 0.195,
              fontWeight: FontWeight.bold,
              color: ringColor,
              letterSpacing: -1,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sprint dots column — vertical progress indicator
// ---------------------------------------------------------------------------

class _SprintDotsColumn extends StatelessWidget {
  const _SprintDotsColumn({required this.timer, required this.pulseCtrl});
  final SprintTimerState timer;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    final total = timer.totalSprints;
    final completedCount =
        timer.isBreak ? timer.sprintNumber : timer.sprintNumber - 1;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final isCompleted = i < completedCount;
        final isCurrent = !timer.isBreak && i == timer.sprintNumber - 1;

        Widget dot = Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isCompleted || isCurrent
                ? const Color(0xFF2563EB)
                : Colors.transparent,
            border: isCompleted || isCurrent
                ? null
                : Border.all(color: const Color(0xFFBFDBFE), width: 2),
          ),
        );

        if (isCurrent) {
          dot = ScaleTransition(
            scale: Tween<double>(begin: 0.82, end: 1.18).animate(
              CurvedAnimation(parent: pulseCtrl, curve: Curves.easeInOut),
            ),
            child: dot,
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: dot,
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Ring painter
// ---------------------------------------------------------------------------

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.ringColor,
    required this.trackColor,
  });

  final double progress;
  final Color ringColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide / 2) - 10;
    const strokeWidth = 11.0;
    const startAngle = -math.pi / 2;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        math.pi * 2 * progress,
        false,
        Paint()
          ..color = ringColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.ringColor != ringColor ||
      old.trackColor != trackColor;
}
