import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../models/todo.dart' show GtdState;
import '../../providers/task_detail_provider.dart';
import '../../widgets/blocked_by_picker.dart';
import '../../widgets/context_tag_picker.dart';
import '../../widgets/project_picker.dart';

class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({super.key, required this.todoId});

  final String todoId;

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _notesController;
  late TextEditingController _timeEstimateController;

  bool _titleInitialized = false;
  bool _notesInitialized = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _notesController = TextEditingController();
    _timeEstimateController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _timeEstimateController.dispose();
    super.dispose();
  }

  TaskDetailNotifier get _notifier =>
      ref.read(taskDetailNotifierProvider(widget.todoId));

  @override
  Widget build(BuildContext context) {
    final todoAsync = ref.watch(taskDetailTodoProvider(widget.todoId));
    final tagsAsync = ref.watch(taskTagsProvider(widget.todoId));
    final blockersAsync = ref.watch(taskBlockersProvider(widget.todoId));

    return todoAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $err')),
      ),
      data: (todo) {
        if (todo == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Task not found')),
          );
        }

        // Initialise text controllers once from the DB row.
        if (!_titleInitialized) {
          _titleController.text = todo.title;
          _titleInitialized = true;
        }
        if (!_notesInitialized) {
          _notesController.text = todo.notes ?? '';
          _notesInitialized = true;
        }
        if (_timeEstimateController.text.isEmpty &&
            todo.timeEstimate != null) {
          _timeEstimateController.text = todo.timeEstimate.toString();
        }

        final tags = tagsAsync.asData?.value ?? [];
        final projectTag =
            tags.where((t) => t.type == 'project').firstOrNull;
        final contextTags =
            tags.where((t) => t.type == 'context').toList();
        final blockers = blockersAsync.asData?.value ?? [];

        return Scaffold(
          appBar: AppBar(
            title: const Text('Edit task'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.pop(),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                  onEditingComplete: () => _notifier
                      .updateTitle(_titleController.text)
                      .ignore(),
                ),
                const SizedBox(height: 16),

                // Notes
                TextField(
                  controller: _notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  onEditingComplete: () => _notifier
                      .updateNotes(_notesController.text)
                      .ignore(),
                ),
                const SizedBox(height: 16),

                // Project picker
                const _SectionLabel(text: 'Project'),
                const SizedBox(height: 6),
                ProjectPickerWidget(
                  currentProjectTag: projectTag,
                  onAssign: (tag) =>
                      _notifier.assignProject(tag.id).ignore(),
                  onClear: () => _notifier.clearProject().ignore(),
                ),
                const SizedBox(height: 16),

                // Context tags
                const _SectionLabel(text: 'Context tags'),
                const SizedBox(height: 6),
                ContextTagPickerWidget(
                  assignedTags: contextTags,
                  onAssign: (tag) =>
                      _notifier.assignContextTag(tag.id).ignore(),
                  onRemove: (tag) =>
                      _notifier.removeContextTag(tag.id).ignore(),
                ),
                const SizedBox(height: 16),

                // Energy level
                const _SectionLabel(text: 'Energy level'),
                const SizedBox(height: 6),
                _EnergySelector(
                  current: todo.energyLevel,
                  onChanged: (level) {
                    if (level == null) {
                      _notifier.clearEnergyLevel().ignore();
                    } else {
                      _notifier.setEnergyLevel(level).ignore();
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Time estimate
                const _SectionLabel(text: 'Time estimate (minutes)'),
                const SizedBox(height: 6),
                TextField(
                  controller: _timeEstimateController,
                  decoration: const InputDecoration(
                    hintText: 'e.g. 30',
                    border: OutlineInputBorder(),
                    suffixText: 'min',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onEditingComplete: () {
                    final val = int.tryParse(_timeEstimateController.text);
                    if (val != null) {
                      _notifier.setTimeEstimate(val).ignore();
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Time spent (read-only)
                if (todo.timeSpentMinutes > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.timer_outlined,
                            size: 16, color: Color(0xFF6B7280)),
                        const SizedBox(width: 6),
                        Text(
                          'Time logged: ${todo.timeSpentMinutes} min',
                          style: const TextStyle(color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ),

                // Blocked by
                const _SectionLabel(text: 'Blocked by'),
                const SizedBox(height: 6),
                BlockedByPickerWidget(
                  potentialBlockers: blockers,
                  currentBlockerId: todo.blockedByTodoId,
                  onChanged: (id) =>
                      _notifier.setBlockedBy(id).ignore(),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
          // Persistent bottom action button
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton.icon(
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Move to…'),
                onPressed: () => _showMoveToSheet(context, todo),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showMoveToSheet(BuildContext context, Todo todo) async {
    final currentState = GtdState.fromString(todo.state);
    final valid = _notifier.validNextStates(currentState);
    if (valid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No further transitions available')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _MoveToSheet(
        currentState: currentState,
        validStates: valid,
        timeSpent: todo.timeSpentMinutes,
        onMove: (newState) async {
          Navigator.of(ctx).pop();
          try {
            await _notifier.transition(newState);
          } catch (e) {
            if (!mounted) return;
            // ignore: use_build_context_synchronously
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e')),
            );
            return;
          }
          // After successfully moving, go back to the previous screen.
          if (!mounted) return;
          // ignore: use_build_context_synchronously
          context.pop();
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF6B7280),
        letterSpacing: 0.3,
      ),
    );
  }
}

class _EnergySelector extends StatelessWidget {
  const _EnergySelector({required this.current, required this.onChanged});

  final String? current;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String?>(
      segments: const [
        ButtonSegment(value: 'low', label: Text('Low')),
        ButtonSegment(value: 'medium', label: Text('Medium')),
        ButtonSegment(value: 'high', label: Text('High')),
      ],
      selected: {current},
      emptySelectionAllowed: true,
      onSelectionChanged: (selection) {
        onChanged(selection.isEmpty ? null : selection.first);
      },
    );
  }
}

class _MoveToSheet extends StatelessWidget {
  const _MoveToSheet({
    required this.currentState,
    required this.validStates,
    required this.timeSpent,
    required this.onMove,
  });

  final GtdState currentState;
  final List<GtdState> validStates;
  final int timeSpent;
  final ValueChanged<GtdState> onMove;

  @override
  Widget build(BuildContext context) {
    final leavingInProgress = currentState == GtdState.inProgress;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Move to…',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (leavingInProgress && timeSpent > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Time logged so far: $timeSpent min',
                  style: const TextStyle(color: Color(0xFF6B7280)),
                ),
              ),
            for (final state in validStates)
              ListTile(
                key: Key('move_to_${state.value}'),
                title: Text(state.displayName),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () => onMove(state),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
