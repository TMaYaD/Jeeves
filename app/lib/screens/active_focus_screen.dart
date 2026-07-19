import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/gtd_database.dart' show Todo;
import '../providers/focus_session_planning_provider.dart'
    show activeSessionTasksProvider;
import '../providers/database_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/sprint_timer_provider.dart';
import '../providers/task_detail_provider.dart';
import '../services/notification_service.dart';
import '../widgets/async_subject.dart';
import '../widgets/elapsed_timer_widget.dart';

class ActiveFocusScreen extends ConsumerStatefulWidget {
  const ActiveFocusScreen({super.key});

  @override
  ConsumerState<ActiveFocusScreen> createState() => _ActiveFocusScreenState();
}

class _ActiveFocusScreenState extends ConsumerState<ActiveFocusScreen>
    with WidgetsBindingObserver {
  Timer? _notificationTimer;
  bool _missingBounceScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Show notification immediately so it persists even if user navigates away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshNotification();
    });
    _notificationTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) _refreshNotification();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationTimer?.cancel();
    // Intentionally do NOT cancel the notification here — it persists so the
    // user can tap back into focus via the status bar while doing something
    // else in the app. The notification is only cancelled when the sprint ends.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh after returning from another app so the phrase is up to date.
    if (state == AppLifecycleState.resumed && mounted) _refreshNotification();
  }

  void _refreshNotification() {
    final focusState = ref.read(focusModeProvider);
    final todoId = focusState.activeTodoId;
    if (todoId == null) return;
    final title =
        ref.read(taskDetailTodoProvider(todoId)).value?.title ?? 'Focus Task';
    final sprintState = ref.read(sprintTimerProvider);
    final phrase = ElapsedTimerWidget.phaseAwarePhrase(
      sprintState: sprintState,
      elapsed: focusState.elapsed,
      activeTodoId: todoId,
    );
    ref.read(notificationServiceProvider).showFocusNotification(
      title: 'In Focus: $title',
      body: phrase,
    );
  }

  Future<void> _onComplete(String todoId) async {
    _notificationTimer?.cancel();
    // Read every dependency up front. The two teardown steps below are awaited,
    // so this widget can unmount across them — the missing-task bounce
    // navigates away, for one — and `ref.read` after disposal throws. Holding
    // the references means completion does not depend on still being mounted.
    final notifications = ref.read(notificationServiceProvider);
    final sprint = ref.read(sprintTimerProvider.notifier);
    final db = ref.read(databaseProvider);
    final focusMode = ref.read(focusModeProvider.notifier);

    // Both are best-effort — completing the task must not fail because a
    // notification could not be cancelled — but they are awaited and logged
    // through [_tryTeardownStep] rather than left as bare discarded futures,
    // so a throw cannot surface as an unhandled async error after this method
    // has already moved on.
    await _tryTeardownStep(
      'cancel focus notification',
      notifications.cancelFocusNotification,
    );
    await _tryTeardownStep('stop sprint', sprint.stopSprint);

    // Deliberately *not* behind a `mounted` check. This is the write the user
    // asked for by tapping Complete; skipping it because the screen went away
    // mid-teardown would silently drop their completion. Only the UI work
    // below is conditional on still being mounted.
    await db.todoDao.markDone(todoId);
    await focusMode.endFocus();
    if (!mounted) return;

    final allSessionTasks = await ref.read(activeSessionTasksProvider.future);
    if (!mounted) return;

    final nextTask = allSessionTasks
        .where((t) => t.id != todoId && t.doneAt == null)
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

  /// Stops the sprint and returns to the focus list without completing the task.
  Future<void> _onStop(String todoId) async {
    _notificationTimer?.cancel();
    // Each step is attempted regardless of the ones before it, for the same
    // reason the missing-task bounce does it: chained, the least important
    // failure suppresses the two that matter. A notification cancel that threw
    // used to skip both `stopSprint` and `endFocus`, so the one control the
    // user has for ending a sprint would leave it running — and tapping Stop
    // again would fail identically, which is not the "visible and retryable"
    // recovery this path was documented to offer.
    //
    // Only `endFocus` failing is worth throwing over, and that asymmetry is
    // about what the user can still do. Focus mode is what keeps this screen
    // reachable, so if clearing it fails the user is genuinely stuck on a
    // sprint they asked to end, and the failure has to surface. The other two
    // are cleanup: by the time they are known to have failed, a successful
    // `endFocus` has already cleared `activeTodoId`, which redirects and
    // unmounts this screen — so re-throwing would raise an error about a
    // screen the user has left, over work they cannot retry, having navigated
    // away regardless. Those are logged instead.
    // Resolved before the first await, as in [_onComplete] and the bounce: each
    // step yields, this widget can be disposed across them, and `ref.read`
    // after disposal throws — which would abandon the teardown mid-way.
    final notifications = ref.read(notificationServiceProvider);
    final sprint = ref.read(sprintTimerProvider.notifier);
    final focusMode = ref.read(focusModeProvider.notifier);

    // Reuses [_tryTeardownStep] rather than a near-identical local closure —
    // the only thing this path needs beyond it is whether *anything* failed,
    // which the bool it already returns answers.
    final cancelled = await _tryTeardownStep(
      'cancel focus notification',
      notifications.cancelFocusNotification,
    );
    final stopped = await _tryTeardownStep('stop sprint', sprint.stopSprint);
    // Deliberately unguarded: this is the one whose failure must reach the
    // caller.
    await focusMode.endFocus();

    if (!mounted) return;
    if (!cancelled || !stopped) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Focus ended, but cleanup was partial.')),
      );
    }
    context.go('/focus');
  }

  /// Runs one best-effort teardown step, logging and swallowing a failure and
  /// reporting whether it succeeded.
  ///
  /// Used by the missing-task bounce, [_onComplete] and [_onStop]; the latter
  /// two differ only in what they do with the bool — [_onStop] keeps it to
  /// decide whether to report a partial failure. All three share the reason for
  /// swallowing: teardown is cleanup around a decision the user has already
  /// made — completing a task, stopping a sprint, leaving a dead one — and a
  /// notification that would not cancel must not take that decision down with
  /// it. What differs is only whether the caller reports the partial failure.
  Future<bool> _tryTeardownStep(
    String label,
    Future<void> Function() run,
  ) async {
    try {
      await run();
      return true;
    } catch (e, stack) {
      debugPrint('Focus teardown step "$label" failed: $e\n$stack');
      return false;
    }
  }

  /// Ends the sprint when its task has been hard-deleted underneath us and
  /// leaves, telling the user why. Guarded because [build] can run many times
  /// while the post-frame callback is still queued.
  ///
  /// This tears the sprint down as thoroughly as [_onStop] does, rather than
  /// only navigating: the SnackBar claims focus ended, and without the teardown
  /// it would be lying. A bare redirect would leave the sprint timer ticking
  /// toward an end-notification for a task that no longer exists, leave the
  /// persistent focus notification in the status bar deep-linking back into the
  /// dead sprint, and leave the TimeLog open against the deleted row.
  void _scheduleMissingBounce() {
    if (_missingBounceScheduled) return;
    _missingBounceScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The messenger is MaterialApp's, not this Scaffold's, so it is resolved
      // up front and survives the redirect — that is what lets the SnackBar
      // still be showing once `/focus` has taken over.
      final messenger = ScaffoldMessenger.of(context);
      // Same reason as the messenger, and as [_onComplete]: every dependency is
      // resolved before the first await. Each step below yields, and this
      // widget can be disposed across them — `ref.read` after disposal throws,
      // which on a one-shot bounce would abandon the rest of the teardown with
      // nothing coming to retry it.
      final notifications = ref.read(notificationServiceProvider);
      final sprint = ref.read(sprintTimerProvider.notifier);
      final focusMode = ref.read(focusModeProvider.notifier);
      _notificationTimer?.cancel();
      // Awaited *before* navigating, exactly as [_onStop] does. Firing these
      // off after `context.go` would let `/focus` build against a container
      // that still reports an active sprint on the deleted task.
      //
      // The teardown is nonetheless best-effort: leaving is not conditional on
      // it succeeding. This bounce is one-shot (`_missingBounceScheduled`), so
      // an escaping exception would strand the user on a blank surface bound
      // to a task that no longer exists, with no second attempt coming — a
      // worse outcome than an incompletely closed sprint.
      //
      // Each step is attempted independently. Chaining them under one `try`
      // lets the *least* important failure suppress the two that matter:
      // a notification cancel that throws would skip `stopSprint` and
      // `endFocus`, leaving focus mode active on a deleted row — precisely the
      // state this teardown exists to clear.
      final cancelled = await _tryTeardownStep(
        'cancel focus notification',
        notifications.cancelFocusNotification,
      );
      final stopped = await _tryTeardownStep('stop sprint', sprint.stopSprint);
      final ended = await _tryTeardownStep('end focus', focusMode.endFocus);
      final endedCleanly = cancelled && stopped && ended;
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          // The failure copy stops short of claiming focus ended, but it no
          // longer sends the user to "Stop on the focus screen" either: every
          // stop control lives behind an active focus mode, so that advice was
          // unreachable precisely when it was offered. `stopSprint` now clears
          // local sprint state even when it throws, so what a failure leaves
          // behind is incomplete cleanup, not a sprint the user must chase.
          content: Text(
            endedCleanly
                ? 'That task no longer exists — focus ended.'
                : 'That task no longer exists. Focus may not have closed '
                    'cleanly.',
          ),
        ),
      );
      context.go('/focus');
    });
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
        child: AsyncSubject<Todo>(
          asyncValue: todoAsync,
          // Focus is a sprint on one task: if that task is gone there is
          // nothing left to focus on, so bouncing back to the focus home beats
          // asking the user to acknowledge a panel. The SnackBar explains the
          // bounce, which the silent redirect never did.
          missingTitle: 'This task no longer exists',
          missingBuilder: (context) {
            _scheduleMissingBounce();
            return const SizedBox.shrink();
          },
          dataBuilder: (context, todo) => _FocusBody(
            todo: todo,
            onComplete: () => _onComplete(todo.id),
            onStop: () => _onStop(todo.id),
          ),
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
  });

  final Todo todo;
  final VoidCallback onComplete;
  final VoidCallback onStop;

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
        // Header: back button + task title
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 24, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back, color: Color(0xFF9CA3AF)),
                onPressed: () => context.go('/focus'),
              ),
              Expanded(
                child: Text(
                  todo.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
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
                onPhaseSkip: timer.isProcessing
                    ? null
                    : () {
                        if (isBreak) {
                          notifier.skipBreak();
                        } else {
                          notifier.startBreak();
                        }
                      },
              ),
              _NotesPage(todo: todo),
            ],
          ),
        ),
        // Page dots
        _PageDots(current: _currentPage),
        // Action bar: Stop | Done (2×)
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[200]!)),
          ),
          child: Row(
            children: [
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
              const SizedBox(width: 8),
              // Done — mark task complete (doubled width)
              Expanded(
                flex: 2,
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
    this.onPhaseSkip,
  });
  final SprintTimerState timer;
  final Color ringColor;
  final AnimationController pulseCtrl;
  final VoidCallback? onPhaseSkip;

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
                onPhaseSkip: onPhaseSkip,
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
  late final FocusNode _focusNode;
  Timer? _saveTimer;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.todo.notes ?? '');
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _isEditing) {
        setState(() => _isEditing = false);
        _saveTimer?.cancel();
        _save();
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    final text = _ctrl.text.trim();
    try {
      // Route notes edits through the DAO so last_clarified_at is stamped
      // consistently — notes edits are a clarifying micro-act per CONTEXT.md.
      // The DAO performs the same single-row update; the prior explicit
      // user check was redundant because this notifier only runs on the
      // current user's own row stream.
      if (text.isEmpty) {
        await db.todoDao.updateFields(widget.todo.id, clearNotes: true);
      } else {
        await db.todoDao.updateFields(widget.todo.id, notes: text);
      }
    } catch (_) {}
  }

  void _startEditing() {
    setState(() => _isEditing = true);
    _ctrl.addListener(_onChanged);
    Future.delayed(const Duration(milliseconds: 50), _focusNode.requestFocus);
  }

  void _stopEditing() {
    _ctrl.removeListener(_onChanged);
    _focusNode.unfocus();
    setState(() => _isEditing = false);
    _saveTimer?.cancel();
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Notes',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151),
                ),
              ),
              const Spacer(),
              if (_isEditing)
                IconButton(
                  icon: const Icon(Icons.check_rounded,
                      size: 18, color: Color(0xFF2563EB)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _stopEditing,
                )
              else
                IconButton(
                  icon: const Icon(Icons.edit_outlined,
                      size: 18, color: Color(0xFF9CA3AF)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _startEditing,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isEditing
                ? TextField(
                    controller: _ctrl,
                    focusNode: _focusNode,
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
                  )
                : _ctrl.text.trim().isEmpty
                    ? GestureDetector(
                        onTap: _startEditing,
                        child: const Text(
                          'Jot down ideas, links, or sub-tasks…',
                          style: TextStyle(
                              fontSize: 15, color: Color(0xFFD1D5DB), height: 1.6),
                        ),
                      )
                    : SingleChildScrollView(
                        child: (() {
                          int checkboxIndex = 0;
                          return MarkdownBody(
                            data: _ctrl.text,
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                  color: Color(0xFF374151)),
                              h1: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1F2937)),
                              h2: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1F2937)),
                              h3: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1F2937)),
                              strong: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1F2937)),
                              em: const TextStyle(fontStyle: FontStyle.italic),
                              listBullet:
                                  const TextStyle(color: Color(0xFF9CA3AF)),
                            ),
                            checkboxBuilder: (bool value) {
                              final currentIdx = checkboxIndex++;
                              return SizedBox(
                                width: 24,
                                height: 24,
                                child: Checkbox(
                                  value: value,
                                  onChanged: (v) {
                                    if (v == null) return;
                                    final lines = _ctrl.text.split('\n');
                                    int found = 0;
                                    for (int i = 0; i < lines.length; i++) {
                                      final line = lines[i];
                                      if (RegExp(r'^\s*[-*+]\s+\[[ xX]\]')
                                              .hasMatch(line) ||
                                          RegExp(r'^\s*\d+\.\s+\[[ xX]\]')
                                              .hasMatch(line)) {
                                        if (found == currentIdx) {
                                          lines[i] = v
                                              ? line
                                                  .replaceFirst('[ ]', '[x]')
                                                  .replaceFirst('[X]', '[x]')
                                              : line
                                                  .replaceFirst('[x]', '[ ]')
                                                  .replaceFirst('[X]', '[ ]');
                                          break;
                                        }
                                        found++;
                                      }
                                    }
                                    final updated = lines.join('\n');
                                    setState(() => _ctrl.text = updated);
                                    _save();
                                  },
                                ),
                              );
                            },
                            onTapLink: (text, href, title) {
                              if (href != null) {
                                launchUrl(Uri.parse(href),
                                        mode: LaunchMode.externalApplication)
                                    .ignore();
                              }
                            },
                          );
                        })(),
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

class _SprintRing extends StatefulWidget {
  const _SprintRing({
    required this.timer,
    required this.size,
    required this.color,
    this.onPhaseSkip,
  });
  final SprintTimerState timer;
  final double size;
  final Color color;
  final VoidCallback? onPhaseSkip;

  @override
  State<_SprintRing> createState() => _SprintRingState();
}

class _SprintRingState extends State<_SprintRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _syncPulse();
  }

  @override
  void didUpdateWidget(_SprintRing old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    final suggest = widget.timer.isNearPhaseEnd;
    if (suggest && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat();
    } else if (!suggest && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.reset();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool overtime = widget.timer.isOvertime;

    final Color ringColor;
    final Color trackColor;
    final double progress;
    final Duration displayTime;

    if (overtime) {
      final p = widget.timer.overtimeProgress;
      ringColor = Color.lerp(
            const Color(0xFFF59E0B),
            const Color(0xFFDC2626),
            p,
          ) ??
          const Color(0xFFDC2626);
      trackColor = const Color(0xFFFEF3C7);
      progress = p;
      displayTime = widget.timer.overtime;
    } else {
      ringColor = widget.color;
      trackColor = widget.timer.isBreak
          ? const Color(0xFFD1FAE5)
          : const Color(0xFFDBEAFE);
      progress = widget.timer.progress;
      displayTime = widget.timer.remaining;
    }

    final minutes =
        displayTime.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        displayTime.inSeconds.remainder(60).toString().padLeft(2, '0');

    final phaseLabel =
        widget.timer.isBreak ? 'Start sprint' : 'Start break';
    final phaseIcon = widget.timer.isBreak
        ? Icons.play_arrow_rounded
        : Icons.coffee_outlined;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          ringColor: ringColor,
          trackColor: trackColor,
          clockwise: widget.timer.isOvertime != widget.timer.isBreak,
        ),
        child: Padding(
          // align column bounds to the inner edge of the ring stroke
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              Text(
                '$minutes:$seconds',
                style: TextStyle(
                  fontSize: widget.size * 0.17,
                  fontWeight: FontWeight.bold,
                  color: ringColor,
                  letterSpacing: -1,
                ),
              ),
              const Spacer(),
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (context, child) {
                  final scale =
                      1.0 + math.sin(_pulseCtrl.value * math.pi) * 0.12;
                  return Transform.scale(scale: scale, child: child);
                },
                child: IconButton(
                  onPressed: widget.onPhaseSkip,
                  tooltip: phaseLabel,
                  icon: Icon(phaseIcon, color: ringColor),
                  iconSize: 36,
                  style: IconButton.styleFrom(
                    backgroundColor: ringColor.withValues(alpha: 0.07),
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
              const Spacer(),
            ],
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
    this.clockwise = true,
  });

  final double progress;
  final Color ringColor;
  final Color trackColor;
  final bool clockwise;

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
      final sweep = (clockwise ? 1 : -1) * math.pi * 2 * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweep,
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
      old.trackColor != trackColor ||
      old.clockwise != clockwise;
}
