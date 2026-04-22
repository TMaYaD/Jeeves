import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/auth_provider.dart';
import '../providers/daily_planning_provider.dart';
import '../providers/database_provider.dart';
import '../providers/focus_session_provider.dart';
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
    _bgNotificationTimer =
        Timer.periodic(const Duration(minutes: 1), (_) {
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
              child: Text(
                message,
                overflow: TextOverflow.ellipsis,
              ),
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

  Future<void> _onAbandon(String todoId) async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.transitionState(todoId, userId, GtdState.deferred);
    ref.read(focusModeProvider.notifier).endFocus();
    if (!mounted) return;
    context.go('/focus');
  }

  Future<void> _onExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Focus Mode?'),
        content: const Text('Your progress timer will be paused.'),
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
              focusState: focusState,
              onTogglePause: () {
                final notifier = ref.read(focusModeProvider.notifier);
                if (focusState.isPaused) {
                  notifier.resumeFocus();
                } else {
                  notifier.pauseFocus();
                }
              },
              onComplete: () => _onComplete(todo.id),
              onAbandon: () => _onAbandon(todo.id),
              onExit: _onExit,
            );
          },
        ),
      ),
    );
  }
}

class _FocusBody extends ConsumerStatefulWidget {
  const _FocusBody({
    required this.todo,
    required this.focusState,
    required this.onTogglePause,
    required this.onComplete,
    required this.onAbandon,
    required this.onExit,
  });

  final Todo todo;
  final FocusModeState focusState;
  final VoidCallback onTogglePause;
  final VoidCallback onComplete;
  final VoidCallback onAbandon;
  final VoidCallback onExit;

  @override
  ConsumerState<_FocusBody> createState() => _FocusBodyState();
}

class _FocusBodyState extends ConsumerState<_FocusBody> {
  late String _notes;

  @override
  void initState() {
    super.initState();
    _notes = widget.todo.notes ?? '';
  }

  @override
  void didUpdateWidget(_FocusBody old) {
    super.didUpdateWidget(old);
    // Sync when an external change arrives (e.g. from task detail screen).
    if (old.todo.notes != widget.todo.notes) {
      setState(() => _notes = widget.todo.notes ?? '');
    }
  }

  void _onCheckboxToggle(int checkboxIndex, bool value) {
    final lines = _notes.split('\n');
    int found = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (RegExp(r'^\s*[-*+]\s+\[[ xX]\]').hasMatch(line) ||
          RegExp(r'^\s*\d+\.\s+\[[ xX]\]').hasMatch(line)) {
        if (found == checkboxIndex) {
          if (value) {
            lines[i] = line
                .replaceFirst('[ ]', '[x]')
                .replaceFirst('[X]', '[x]');
          } else {
            lines[i] = line
                .replaceFirst('[x]', '[ ]')
                .replaceFirst('[X]', '[ ]');
          }
          break;
        }
        found++;
      }
    }
    final updated = lines.join('\n');
    setState(() => _notes = updated);
    ref
        .read(taskDetailNotifierProvider(widget.todo.id))
        .updateNotes(updated)
        .ignore();
  }

  Widget _buildNotes() {
    if (_notes.isEmpty) return const SizedBox.shrink();
    int checkboxIndex = 0;
    return MarkdownBody(
      data: _notes,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
            fontSize: 16, height: 1.5, color: Color(0xFF6B7280)),
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
            fontWeight: FontWeight.bold, color: Color(0xFF374151)),
        em: const TextStyle(fontStyle: FontStyle.italic),
        listBullet: const TextStyle(color: Color(0xFF9CA3AF)),
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
              _onCheckboxToggle(currentIdx, v);
            },
          ),
        );
      },
      onTapLink: (text, href, title) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication)
              .ignore();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final focusState = widget.focusState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Chrome: task title alongside the close X. The pair reads as one
        // header zone; neither element distracts from the Jeeves banner
        // below, which is where the eye next lands.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 4, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    todo.title,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                      height: 1.3,
                    ),
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
        // Jeeves elapsed reminder — parchment banner at the threshold
        // between chrome and content. "I merely observe, sir."
        const ElapsedTimerWidget(),
        // Notes area — unshared scroll zone; the banner above doesn't scroll.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_notes.isNotEmpty) _buildNotes(),
              ],
            ),
          ),
        ),
        // Action bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey[200]!)),
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onTogglePause,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(focusState.isPaused ? 'Resume' : 'Pause'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: widget.onComplete,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2667B7),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Complete'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onAbandon,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red[600],
                    side: BorderSide(color: Colors.red[300]!),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Abandon'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
