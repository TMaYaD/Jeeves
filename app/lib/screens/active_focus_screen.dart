import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../database/gtd_database.dart' show GtdDatabase, Todo;
import '../providers/focus_session_planning_provider.dart'
    show
        SessionSettlement,
        activeSessionSettlementsProvider,
        activeSessionTasksProvider;
import '../providers/database_provider.dart';
import '../providers/focus_session_provider.dart';
import '../providers/sprint_timer_provider.dart';
import '../providers/task_detail_provider.dart';
import '../services/clarification_service.dart';
import '../services/notification_service.dart';
import '../widgets/app_title_bar/app_title_bar.dart';
import '../widgets/async_subject.dart' show SubjectPresence;
import '../widgets/capture/capture_action.dart';
import '../widgets/elapsed_timer_widget.dart';
import '../widgets/process_to_handlers.dart' show ProcessAction;
import '../widgets/reclarify_prompt_sheet.dart';

/// The focus-list transition message shown after a Focus "Done" verdict
/// resolves.
///
/// "All done for today!" is claimed **only** on a genuine achieved-and-last
/// verdict. This keys on the achieved verdict specifically ([ProcessAction.done]),
/// not on any truthy resolution: every "More to do" save resolves as
/// [ProcessAction.nextActionDialog] — whether the user typed a phrase or left
/// it empty and took the title-as-action fallback — and neither
/// achieves the Outcome, so neither may claim "All done". A `null` verdict
/// (the prompt was dismissed) is likewise not an achievement.
@visibleForTesting
String focusAdvanceMessage({
  required Todo? nextTask,
  required ProcessAction? verdict,
}) {
  if (nextTask != null) return 'Done! Next up: ${nextTask.title}';
  return verdict == ProcessAction.done
      ? 'All done for today!'
      : 'Sprint logged — nothing else planned.';
}

/// The task the session advances to after a Focus "Done" verdict on
/// [completedTodoId] — the first Plan member still owed attention.
///
/// Extracted for the same reason as [focusAdvanceMessage]: `_onComplete`'s tail
/// awaits a Riverpod stream-provider future that a fake-clock `pump` cannot get
/// past, so the decision is pinned here rather than through the screen.
///
/// A **Settled** task is skipped (#693 AC2): the user has already answered for
/// it this session, so re-presenting it as "next up" would hand back work they
/// are done with. `doneAt` stays as the cheap guard — a Settled done row is in
/// [settlements] anyway.
@visibleForTesting
Todo? focusNextTask({
  required List<Todo> sessionTasks,
  required String completedTodoId,
  required Map<String, SessionSettlement> settlements,
}) =>
    sessionTasks
        .where((t) =>
            t.id != completedTodoId &&
            t.doneAt == null &&
            !settlements.containsKey(t.id))
        .firstOrNull;

class ActiveFocusScreen extends ConsumerStatefulWidget {
  const ActiveFocusScreen({super.key});

  @override
  ConsumerState<ActiveFocusScreen> createState() => _ActiveFocusScreenState();
}

class _ActiveFocusScreenState extends ConsumerState<ActiveFocusScreen>
    with WidgetsBindingObserver {
  Timer? _notificationTimer;

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
    NotificationService.instance.showFocusNotification(
      title: 'In Focus: $title',
      body: phrase,
    );
  }

  Future<void> _onComplete(Todo todo) async {
    final todoId = todo.id;
    _notificationTimer?.cancel();
    NotificationService.instance.cancelFocusNotification();
    // Await the stop: stopSprint() persists sprint history (via _clearPrefs)
    // before returning, so discarding the future would swallow storage errors
    // and race the cleanup against completeCurrentAction. The first context use
    // below (the re-clarify sheet) is already guarded by `if (!mounted)`, and
    // the sheet still floats *before* endFocus() — this await adds no gap ahead
    // of an unguarded context access. No `mounted` guard follows: the
    // Action-completion write below must land even if the widget unmounts
    // mid-stop (the Done must never be lost), and it touches no context.
    await ref.read(sprintTimerProvider.notifier).stopSprint();

    // Done completes the current *Action* — an engagement signal, not a
    // declaration that the *Outcome* is achieved (CONTEXT.md § GTD Core). This
    // terminates the Action (role='done' + done_at), clears the cursor, and
    // deliberately does NOT stamp last_clarified_at, leaving the Outcome
    // Actionless and owing a re-clarification.
    await ref.read(clarificationServiceProvider).completeCurrentAction(todoId);
    if (!mounted) return;

    // Float the re-clarify prompt *before* endFocus(): endFocus() nulls
    // activeTodoId, which the build redirect (top of this screen) turns into a
    // navigation to /focus that would close the sheet underneath the user. The
    // Action-completion write already landed above, so dismissing the sheet
    // (or process death mid-prompt) can never lose the Done.
    final verdict = await ReclarifyPromptSheet.show(context, todo);
    if (!mounted) return;

    final allSessionTasks = await ref.read(activeSessionTasksProvider.future);
    if (!mounted) return;
    final settlements =
        await ref.read(activeSessionSettlementsProvider.future);
    if (!mounted) return;

    // The completed Action's Outcome is excluded by `t.id != todoId` whether or
    // not it was achieved, so the advance-to-next pick is unchanged (AC5).
    final nextTask = focusNextTask(
      sessionTasks: allSessionTasks,
      completedTodoId: todoId,
      settlements: settlements,
    );

    final message = focusAdvanceMessage(nextTask: nextTask, verdict: verdict);

    // Show the transition snackbar and end the session while the screen is
    // still active, *before* endFocus() nulls activeTodoId. endFocus() would
    // otherwise trip the build redirect to /focus and unmount this screen,
    // dropping the snackbar. The snackbar lives on the root ScaffoldMessenger,
    // so it survives the subsequent navigation.
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

    await ref.read(focusModeProvider.notifier).endFocus();
    if (!mounted) return;
    context.go('/focus');
  }

  /// Stops the sprint and returns to the focus list without completing the task.
  Future<void> _onStop(String todoId) async {
    _notificationTimer?.cancel();
    NotificationService.instance.cancelFocusNotification();
    await ref.read(sprintTimerProvider.notifier).stopSprint();
    await ref.read(focusModeProvider.notifier).endFocus();
    if (!mounted) return;
    context.go('/focus');
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
      // Leaving focus is a router `go` back to the execution home, not a
      // Navigator pop (this route was reached by `go`), so the bar's way out
      // is overridden. The title single-lines the task (chrome unification).
      appBar: AppTitleBar(
        title: todoAsync.value?.title ?? '',
        onLeadingPressed: () => context.go('/focus'),
        pinnedAction: captureAction(context),
      ),
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
              onComplete: () => _onComplete(todo),
              onStop: () => _onStop(todo.id),
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
        // The back affordance and task title live in the shared title bar
        //; the sprint-aware Jeeves banner leads the body.
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

  /// The database handle, captured while the element is still mounted so
  /// [dispose] can issue the pending-notes flush.
  ///
  /// `dispose()` cannot reach it through `ref`: `StatefulElement.unmount()`
  /// marks the element defunct — so `context.mounted` goes false — *before* it
  /// calls `state.dispose()`, and Riverpod's `ref` asserts on exactly that
  /// (#529). Every other read here runs while mounted and goes through `ref`.
  late final GtdDatabase _databaseForDisposeFlush;

  /// The notes as last written (or as the row was read), in the trimmed form
  /// [_writeNotes] stores. The flush writes only what differs from it —
  /// [TodoDao.updateFields] stamps `updated_at` and `last_clarified_at` and
  /// authors a sync op, so an unconditional flush would restamp clarification
  /// every time the user left the focus screen.
  String? _baselineNotes;

  /// Latched once local storage has confirmed this Outcome is gone — see where
  /// it is set in [build].
  bool _subjectConfirmedMissing = false;

  @override
  void initState() {
    super.initState();
    _databaseForDisposeFlush = ref.read(databaseProvider);
    _ctrl = TextEditingController(text: widget.todo.notes ?? '');
    _baselineNotes = (widget.todo.notes ?? '').trim();
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
    _flushPendingNotes();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// The last line of defence for a notes edit still in the field when the page
  /// goes — including one typed inside the 500ms debounce window the line above
  /// has just cancelled.
  ///
  /// Focus loss and the debounce stay the primary triggers (ADR-0023); this
  /// only puts a floor under them. No `ref.read` / `ref.watch` in here — see
  /// [_databaseForDisposeFlush].
  void _flushPendingNotes() {
    // A write must not outlive its subject.
    if (_subjectConfirmedMissing) return;
    // Snapshot everything before anything is disposed.
    final text = _ctrl.text.trim();
    if (text == _baselineNotes) return;
    unawaited(_writeNotes(_databaseForDisposeFlush, widget.todo.id, text));
  }

  void _onChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() =>
      _writeNotes(ref.read(databaseProvider), widget.todo.id, _ctrl.text.trim());

  /// The one write path, shared by the debounce, the focus-loss save and the
  /// dispose flush, so the exits cannot drift apart. Takes its database and
  /// subject id as arguments because [dispose] can supply neither through
  /// `ref`.
  Future<void> _writeNotes(GtdDatabase db, String todoId, String text) async {
    try {
      // Route notes edits through the DAO so last_clarified_at is stamped
      // consistently — notes edits are a clarifying micro-act per CONTEXT.md.
      // The DAO performs the same single-row update; the prior explicit
      // user check was redundant because this notifier only runs on the
      // current user's own row stream.
      if (text.isEmpty) {
        await db.todoDao.updateFields(todoId, clearNotes: true);
      } else {
        await db.todoDao.updateFields(todoId, notes: text);
      }
      _baselineNotes = text;
    } catch (e) {
      // The page may already be gone, so there is no surface left to tell the
      // user on. Uncaught, a throwing DAO would escape as an unhandled async
      // error from teardown, which reads as a framework fault rather than a
      // lost edit.
      debugPrint('ActiveFocusScreen: notes write failed: $e');
    }
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
    // A write must not outlive its subject (#446 / #447). This page receives
    // its [Todo] from the parent, so it latches its own signal off the same
    // provider the parent watches. The parent's null branch swaps the body out
    // and routes away, so this page is genuinely torn down at the moment the
    // row goes — an unguarded flush would write to the deleted row on the
    // ordinary path, not a rare one.
    //
    // **Latched, never cleared:** un-latching on a row that comes back is live
    // re-binding, which #447 puts out of scope (#427). `dispose()` reads the
    // latch rather than the provider, because reading a provider there is the
    // #529 trap.
    //
    // The window between the last emission and the flush is #444's; the durable
    // answer is one guard at the write seam, not a latch per surface — #447
    // should replace this rather than copy it onto the next one.
    ref.listen<AsyncValue<Todo?>>(
      taskDetailTodoProvider(widget.todo.id),
      (previous, next) {
        if (next.subjectConfirmedMissing) _subjectConfirmedMissing = true;
      },
    );

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
