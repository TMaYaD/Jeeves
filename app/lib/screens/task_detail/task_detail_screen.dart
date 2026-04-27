import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/gtd_database.dart';
import '../../models/todo.dart' show GtdState;
import '../../providers/task_detail_provider.dart';
import '../../widgets/context_tag_picker.dart';
import '../../widgets/project_picker.dart';
import '../../widgets/tag_list.dart';

class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({super.key, required this.todoId});

  final String todoId;

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _notesController;
  late FocusNode _titleFocusNode;
  late FocusNode _notesFocusNode;

  bool _titleInitialized = false;
  bool _notesInitialized = false;
  bool _isEditingNotes = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _notesController = TextEditingController();

    _titleFocusNode = FocusNode();
    _notesFocusNode = FocusNode();

    _titleFocusNode.addListener(() {
      if (!_titleFocusNode.hasFocus && mounted) {
        ref
            .read(taskDetailNotifierProvider(widget.todoId))
            .updateTitle(_titleController.text)
            .catchError((e) => debugPrint('Error saving title: $e'));
      }
    });

    _notesFocusNode.addListener(() {
      if (!_notesFocusNode.hasFocus && mounted) {
        setState(() {
          _isEditingNotes = false;
        });
        ref
            .read(taskDetailNotifierProvider(widget.todoId))
            .updateNotes(_notesController.text)
            .catchError((e) => debugPrint('Error saving notes: $e'));
      }
    });
  }

  @override
  void dispose() {
    _titleFocusNode.dispose();
    _notesFocusNode.dispose();
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  TaskDetailNotifier get _notifier =>
      ref.read(taskDetailNotifierProvider(widget.todoId));

  @override
  Widget build(BuildContext context) {
    final todoAsync = ref.watch(taskDetailTodoProvider(widget.todoId));
    final tagsAsync = ref.watch(taskTagsProvider(widget.todoId));

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: todoAsync.when(
        loading: () => const Scaffold(
          backgroundColor: Colors.white,
          body: Center(child: CircularProgressIndicator()),
        ),
        error: (err, _) => Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
          body: Center(child: Text('Error: $err')),
        ),
        data: (todo) {
          if (todo == null) {
            return Scaffold(
              backgroundColor: Colors.white,
              appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
              body: const Center(child: Text('Task not found')),
            );
          }

          if (!_titleInitialized) {
            _titleController.text = todo.title;
            _titleInitialized = true;
          }
          if (!_notesInitialized) {
            _notesController.text = todo.notes ?? '';
            _notesInitialized = true;
          }

          final tags = tagsAsync.asData?.value ?? [];
          final projectTag = tags.where((t) => t.type == 'project').firstOrNull;
          final contextTags = tags.where((t) => t.type == 'context').toList();

          return Scaffold(
            backgroundColor: Colors.white,
            appBar: _buildAppBar(todo),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Segment
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Project Picker Custom UI
                      ProjectPickerWidget(
                        currentProjectTag: projectTag,
                        onAssign: (tag) => _notifier.assignProject(tag.id).ignore(),
                        onClear: () => _notifier.clearProject().ignore(),
                        customChild: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.folder_outlined, color: Color(0xFF2563EB), size: 16),
                              const SizedBox(width: 4),
                              Text(
                                projectTag?.name.toUpperCase() ?? 'ADD PROJECT',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF2563EB),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Title TextField (Show-mode styled)
                      TextField(
                        controller: _titleController,
                        focusNode: _titleFocusNode,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          hintText: 'Task Title',
                          hintStyle: TextStyle(color: Color(0xFFD1D5DB)),
                        ),
                        maxLines: null,
                      ),
                      const SizedBox(height: 16),
                      // Context Tags
                      TagList(
                        tags: contextTags,
                        spacing: 12,
                        runSpacing: 8,
                        onTap: (_) => _showContextTagEditor(context),
                        trailing: GestureDetector(
                          onTap: () => _showContextTagEditor(context),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFD1D5DB)),
                            ),
                            child: const Icon(Icons.add, size: 16, color: Color(0xFF9CA3AF)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Attributes Row (Status, Time, Energy)
                      Row(
                        children: [
                          Expanded(flex: 2, child: _buildStatusPill(todo)),
                          const SizedBox(width: 8),
                          Expanded(flex: 1, child: _buildAttributeItem(
                            icon: Icons.schedule,
                            text: todo.timeEstimate != null ? '${todo.timeEstimate}m' : 'Time',
                            onTap: () => _showTimeEstimateSheet(context, todo.timeEstimate),
                          )),
                          const SizedBox(width: 8),
                          Expanded(flex: 1, child: _buildAttributeItem(
                            icon: Icons.bolt,
                            text: todo.energyLevel != null ? '${todo.energyLevel!.substring(0, 1).toUpperCase()}${todo.energyLevel!.substring(1)}' : 'Energy',
                            onTap: () => _showEnergyLevelSheet(context, todo.energyLevel),
                          )),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
                // Body area (scrollable with push-to-bottom logic)
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: constraints.maxHeight),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Notes Area
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.notes, size: 16, color: Colors.grey[400]),
                                        const SizedBox(width: 8),
                                        const Text(
                                          'NOTES',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 1.2,
                                            color: Color(0xFF9CA3AF),
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF9CA3AF)),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () {
                                            setState(() => _isEditingNotes = true);
                                            Future.delayed(const Duration(milliseconds: 50), () {
                                              _notesFocusNode.requestFocus();
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    _isEditingNotes
                                        ? TextField(
                                            controller: _notesController,
                                            focusNode: _notesFocusNode,
                                            maxLines: null,
                                            style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF1F2937)),
                                            decoration: const InputDecoration(
                                              border: InputBorder.none,
                                              isDense: true,
                                              contentPadding: EdgeInsets.zero,
                                              hintText: 'Start typing thoughts, checklists, or details for this task...',
                                              hintStyle: TextStyle(color: Color(0xFFD1D5DB)),
                                            ),
                                          )
                                        : Container(
                                            constraints: const BoxConstraints(minHeight: 100, minWidth: double.infinity),
                                            child: _notesController.text.trim().isEmpty
                                                ? const Text(
                                                    'Start typing thoughts, checklists, or details for this task...',
                                                    style: TextStyle(fontSize: 16, height: 1.5, color: Color(0xFFD1D5DB)),
                                                  )
                                                : (() {
                                                    int checkboxIndex = 0;
                                                    return MarkdownBody(
                                                      data: _notesController.text,
                                                      selectable: true,
                                                      styleSheet: MarkdownStyleSheet(
                                                        p: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xFF1F2937)),
                                                        h1: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                                                        h2: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                                                        h3: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                                                        strong: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF111827)),
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
                                                              // Toggle the nth checkbox in the markdown string
                                                              final lines = _notesController.text.split('\n');
                                                              int foundCheckboxes = 0;
                                                              for (int i = 0; i < lines.length; i++) {
                                                                final line = lines[i];
                                                                if (RegExp(r'^\s*[-*+]\s+\[[ xX]\]').hasMatch(line) || RegExp(r'^\s*\d+\.\s+\[[ xX]\]').hasMatch(line)) {
                                                                  if (foundCheckboxes == currentIdx) {
                                                                    if (v) {
                                                                      lines[i] = line.replaceFirst('[ ]', '[x]').replaceFirst('[X]', '[x]');
                                                                    } else {
                                                                      lines[i] = line.replaceFirst('[x]', '[ ]').replaceFirst('[X]', '[ ]');
                                                                    }
                                                                    break;
                                                                  }
                                                                  foundCheckboxes++;
                                                                }
                                                              }
                                                              final newNotes = lines.join('\n');
                                                              setState(() => _notesController.text = newNotes);
                                                              _notifier.updateNotes(newNotes).ignore();
                                                            },
                                                          ),
                                                        );
                                                      },
                                                      onTapLink: (text, href, title) {
                                                        if (href != null) {
                                                          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication).ignore();
                                                        }
                                                      },
                                                    );
                                                  })(),
                                          ),
                                  ],
                                ),
                              ),
                              // Reminders, Due Date, Blockers (at the literal bottom of the viewport or content)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF9FAFB),
                                  border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
                                ),
                                child: Column(
                                  children: [
                                    _buildInfoSection(
                                      icon: Icons.notifications_none,
                                      iconBg: const Color(0xFFF3F4F6),
                                      iconColor: const Color(0xFF9CA3AF),
                                      title: 'REMINDERS',
                                      contentWidget: const Text('Coming Soon', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
                                      onTap: null, // Disabled and greyed
                                    ),
                                    const SizedBox(height: 20),
                                    _buildInfoSection(
                                      icon: Icons.calendar_today_outlined,
                                      iconBg: const Color(0xFFFEF2F2),
                                      iconColor: const Color(0xFFEF4444),
                                      title: 'DUE DATE',
                                      contentWidget: Text(
                                        todo.dueDate != null ? todo.dueDate!.toLocal().toString().split(' ')[0] : 'No Date',
                                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                                      ),
                                      onTap: () async {
                                        final picked = await showDatePicker(
                                          context: context,
                                          // Storage is UTC; DatePicker reads
                                          // year/month/day verbatim, so feed
                                          // the local-tz instant.
                                          initialDate: todo.dueDate?.toLocal() ?? DateTime.now(),
                                          firstDate: DateTime(2000),
                                          lastDate: DateTime(2100),
                                          builder: (ctx, child) => Theme(
                                            data: ThemeData.light().copyWith(
                                              colorScheme: const ColorScheme.light(primary: Color(0xFF2563EB)),
                                            ),
                                            child: child!,
                                          ),
                                        );
                                        if (picked != null) {
                                          _notifier.setDueDate(picked);
                                        } else {
                                          _notifier.clearDueDate();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  AppBar _buildAppBar(Todo todo) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 20, color: Colors.black),
        onPressed: () => context.pop(),
      ),
      actions: const [],
    );
  }

  Widget _buildStatusPill(Todo todo) {
    final currentState = GtdState.fromString(todo.state);
    return InkWell(
      key: const Key('status_pill'),
      onTap: () => _showMoveToSheet(context, todo),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: switch (currentState) {
                  GtdState.inbox => const Color(0xFF3B82F6),
                  _ => const Color(0xFF10B981),
                },
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              currentState.displayName,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF4B5563)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttributeItem({required IconData icon, required String text, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: const Color(0xFF9CA3AF)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoSection({required IconData icon, required Color iconBg, required Color iconColor, required String title, required Widget contentWidget, VoidCallback? onTap}) {
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: iconColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 2),
              contentWidget,
            ],
          ),
        ),
      ],
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: body,
        ),
      );
    }
    return body;
  }

  void _showContextTagEditor(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      // The modal lives under the root Navigator overlay, so it does not
      // rebuild when the task detail screen rebuilds.  Wrap in [Consumer]
      // so FilterChip's `selected` state tracks taskTagsProvider live —
      // otherwise the chip's "selected" flag is frozen at open time and
      // tapping it appears to do nothing even though the DB write
      // succeeded.
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom + 24, left: 24, right: 24, top: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit Context Tags', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Consumer(
              builder: (context, ref, _) {
                final tags =
                    ref.watch(taskTagsProvider(widget.todoId)).asData?.value ??
                        const <Tag>[];
                final contextTags =
                    tags.where((t) => t.type == 'context').toList();
                return ContextTagPickerWidget(
                  assignedTags: contextTags,
                  onAssign: (tag) =>
                      _notifier.assignContextTag(tag.id).ignore(),
                  onRemove: (tag) =>
                      _notifier.removeContextTag(tag.id).ignore(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTimeEstimateSheet(BuildContext context, int? current) async {
    final times = [5, 10, 15, 30, 45, 60, 90, 120, null];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text('Time Estimate', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(color: Color(0xFFF3F4F6)),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: times.map((val) => ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text(val == null ? 'None' : '${val}m', style: const TextStyle(color: Color(0xFF374151))),
                    trailing: val == current ? const Icon(Icons.check, color: Color(0xFF2563EB)) : null,
                    onTap: () {
                      if (val == null) {
                        _notifier.clearTimeEstimate();
                      } else {
                        _notifier.setTimeEstimate(val);
                      }
                      Navigator.pop(ctx);
                    },
                  )).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showEnergyLevelSheet(BuildContext context, String? current) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Energy Level', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              SegmentedButton<String?>(
                segments: const [
                  ButtonSegment(value: 'low', label: Text('Low')),
                  ButtonSegment(value: 'medium', label: Text('Medium')),
                  ButtonSegment(value: 'high', label: Text('High')),
                ],
                selected: {current},
                emptySelectionAllowed: true,
                onSelectionChanged: (s) {
                  if (s.isEmpty || s.first == null) {
                    _notifier.clearEnergyLevel();
                  } else {
                    _notifier.setEnergyLevel(s.first!);
                  }
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMoveToSheet(BuildContext context, Todo todo) async {
    final currentState = GtdState.fromString(todo.state);
    final valid = _notifier.validNextStates(currentState);
    if (valid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No further transitions available')));
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
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
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
            return;
          }
        },
      ),
    );
  }
}

class _MoveToSheet extends StatelessWidget {
  const _MoveToSheet({
    required this.currentState, required this.validStates, required this.timeSpent, required this.onMove,
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(padding: EdgeInsets.all(16), child: Text('Move to…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              if (leavingInProgress && timeSpent > 0)
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Time logged so far: $timeSpent min', style: const TextStyle(color: Color(0xFF6B7280)))),
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
      ),
    );
  }
}
