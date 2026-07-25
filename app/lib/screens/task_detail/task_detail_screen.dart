// The Drift `Action` row type (issue #475) collides with Material's
// `Action<Intent>` widget class; this screen uses no Material `Action`, so hide
// it and keep the domain type.
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/gtd_database.dart';
import '../../providers/focus_session_provider.dart';
import '../../providers/sprint_timer_provider.dart' show sprintTimerProvider;
import '../../providers/task_detail_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../../widgets/async_subject.dart';
import '../../widgets/context_tag_picker.dart';
import '../../widgets/project_picker.dart';
import '../../widgets/tag_list.dart';
import '../../widgets/task_status_row.dart';

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
      child: AsyncSubject<Todo>(
        asyncValue: todoAsync,
        // Same copy as the clarify surfaces: to the user an Outcome that is
        // gone is gone, whichever screen was showing it.
        missingTitle: 'This item is no longer here',
        missingIcon: Icons.inventory_2_outlined,
        missingSubtitle: 'It was removed while you had it open.',
        missingCta: Builder(
          builder: (context) => TextButton(
            onPressed: () => context.pop(),
            child: const Text('Go back'),
          ),
        ),
        // dataBuilder returns a whole route, so the other three surfaces need
        // the same chrome around them — not least the app bar's back arrow.
        surfaceWrapper: (context, surface) => Scaffold(
          backgroundColor: Colors.white,
          appBar: AppTitleBar(
            title: '',
            onLeadingPressed: _back,
            pinnedAction: captureAction(context),
          ),
          body: surface,
        ),
        dataBuilder: (context, todo) {
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
            appBar: _buildTitleBar(todo, projectTag),
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
                          Expanded(
                            flex: 2,
                            child: tagsAsync.asData != null
                                ? TaskStatusRow(todo: todo, tags: tags)
                                : const SizedBox.shrink(),
                          ),
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
                              // Plan + Notes grouped so spaceBetween still pins
                              // Reminders / Due to the bottom of the viewport.
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Plan section (planned queue) above Notes —
                                  // the Outcome's "what's next" (ADR-0004)
                                  // outranks free-text notes.
                                  _PlanSection(outcomeId: widget.todoId),
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
                                ],
                              ),
                              // Reminders, Due Date (at the literal bottom of the viewport or content)
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
                                      onTap: null,
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
                                    // "Captured from…" provenance — hidden when
                                    // the Outcome has no capture links (issue
                                    // #184 Phase 4).
                                    _CapturedFromSection(outcomeId: widget.todoId),
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

  /// The screen's way out. Shared by the loaded title bar and the one
  /// [AsyncSubject.surfaceWrapper] puts around the loading / error / missing
  /// surfaces, and passed explicitly rather than left to [AppTitleBar]'s
  /// default: the default pops the [Navigator], while this screen leaves
  /// through the router, and the way out must not change shape when the body
  /// does.
  void _back() => context.pop();

  /// The screen's chrome (ADR-0021). The bar carries the read-only identity of
  /// the Outcome — project as the overline, title as the title — while the
  /// body keeps the editable title field and project picker.
  AppTitleBar _buildTitleBar(Todo todo, Tag? projectTag) {
    return AppTitleBar(
      title: todo.title,
      overline: projectTag == null
          ? null
          : AppTitleBarOverline(
              label: projectTag.name,
              icon: Icons.folder_outlined,
              iconColor: const Color(0xFF2563EB),
            ),
      onLeadingPressed: _back,
      pinnedAction: captureAction(context),
      pageActions: [
        // Ad-hoc engagement entry point (issue #180): works with or without
        // an open FocusSession — engagement is independent of the session
        // (ADR-0005). An icon action in the shared bar, keeping the primary
        // blue as its foreground so it still reads as the call to action.
        if (todo.doneAt == null)
          AppTitleBarAction(
            key: const Key('task_detail_start_focus'),
            icon: Icons.play_arrow_rounded,
            label: 'Start focus',
            color: const Color(0xFF2667B7),
            onPressed: () => _startFocus(todo),
          ),
      ],
    );
  }

  /// Engages [todo]: navigates straight to the active-focus screen when this
  /// task is already the one in focus (mirrors the execution home's Start
  /// button short-circuits), otherwise starts a new engagement via
  /// [FocusModeNotifier.startFocus].
  ///
  /// Engagement is sequential (CONTEXT.md § TimeLog): while another task's
  /// engagement is live — in-memory focus state, or a persisted sprint that
  /// survived a restart — starting here would strand the open TimeLog or
  /// sprint, so the conflict is surfaced instead.
  Future<void> _startFocus(Todo todo) async {
    final sprint = ref.read(sprintTimerProvider);
    final activeFocusId = ref.read(focusModeProvider).activeTodoId;
    // Conflicts come first: a tracker (sprint or Focus) owned by a
    // different task must never be masked by the other tracker matching
    // this one — navigating would leave the conflicting engagement
    // undisclosed.
    if ((sprint.isActive && sprint.activeTaskId != todo.id) ||
        (activeFocusId != null && activeFocusId != todo.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Another task is already in focus — finish or stop it '
                  'first.'),
        ),
      );
      return;
    }
    // Past the conflict check, every live tracker belongs to [todo]:
    // resume the existing engagement rather than starting a new one
    // (mirrors the execution home's Start button short-circuits).
    if (sprint.isActive || activeFocusId != null) {
      context.push('/focus/active');
      return;
    }
    await ref.read(focusModeProvider.notifier).startFocus(todo.id);
    if (mounted) context.push('/focus/active');
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
}

/// "Captured from…" provenance for an Outcome (issue #184 Phase 4).
///
/// Collapsed by default; lists each source Capture's raw fragment and when it
/// was captured. Renders nothing when the Outcome has no `capture_outcomes`
/// links — historical Outcomes (created before the Capture split, or outside
/// the clarify flow) simply show no section, so no threshold logic is needed.
class _CapturedFromSection extends ConsumerWidget {
  const _CapturedFromSection({required this.outcomeId});

  final String outcomeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capturesAsync = ref.watch(capturesForOutcomeProvider(outcomeId));
    final captures = capturesAsync.asData?.value ?? const <Capture>[];
    if (captures.isEmpty) return const SizedBox.shrink();

    final count = captures.length;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Theme(
        // Strip the default divider lines so the tile matches the flat
        // info-section styling above it.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        // ExpansionTile renders a ListTile, which paints its ink splash on the
        // nearest Material ancestor. This section sits inside the footer's
        // decorated Container (a DecoratedBox with a background colour), which
        // would hide those splashes — Flutter asserts on exactly that. A
        // transparency Material gives the tile its own ink surface without
        // painting over the footer's background.
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
          key: const Key('captured_from_section'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
          leading: const Icon(Icons.inbox_outlined,
              size: 18, color: Color(0xFF9CA3AF)),
          title: Text(
            count == 1 ? 'Captured from 1 capture' : 'Captured from $count captures',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: Color(0xFF6B7280),
            ),
          ),
          children: [
            for (final capture in captures)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      capture.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF374151),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _capturedAtLabel(capture.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _capturedAtLabel(DateTime createdAt) {
    final local = createdAt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return 'Captured $y-$m-$d';
  }
}

/// The Outcome's **Plan** (ADR-0004 story 5, issue #475): the current Action as
/// an anchor row (with a demote affordance), the ordered planned queue, and an
/// inline add affordance. Planned Actions are only ever shown here — they are
/// not engageable (CONTEXT.md § Action).
///
/// Promotion is an explicit clarifying act: with no current Action the up-arrow
/// promotes directly; with a current Action it opens the "Replace current
/// action" confirm sheet (supersede-and-promote), never a silent replace. No
/// SnackBars — every affordance is inline, per the screen's idiom.
class _PlanSection extends ConsumerStatefulWidget {
  const _PlanSection({required this.outcomeId});

  final String outcomeId;

  @override
  ConsumerState<_PlanSection> createState() => _PlanSectionState();
}

class _PlanSectionState extends ConsumerState<_PlanSection> {
  static const _muted = Color(0xFF9CA3AF);
  static const _ink = Color(0xFF1F2937);

  bool _adding = false;
  late final TextEditingController _addController;
  late final FocusNode _addFocus;

  String? _editingId;
  late final TextEditingController _editController;
  late final FocusNode _editFocus;

  @override
  void initState() {
    super.initState();
    _addController = TextEditingController();
    _addFocus = FocusNode();
    _editController = TextEditingController();
    _editFocus = FocusNode();
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _editingId != null) _commitEdit();
    });
  }

  @override
  void dispose() {
    _addController.dispose();
    _addFocus.dispose();
    _editController.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  TaskDetailNotifier get _notifier =>
      ref.read(taskDetailNotifierProvider(widget.outcomeId));

  void _submitAdd() {
    final text = _addController.text.trim();
    if (text.isNotEmpty) _notifier.addPlannedAction(text).ignore();
    _addController.clear();
    setState(() => _adding = false);
  }

  void _startEdit(Action row) {
    setState(() {
      _editingId = row.id;
      _editController.text = row.actionText;
    });
    Future.delayed(const Duration(milliseconds: 50), () {
      // The row can be disposed within the delay (navigate away, or the row
      // disappears via a sync) — requesting focus on a dead node would throw.
      if (!mounted) return;
      _editFocus.requestFocus();
    });
  }

  void _commitEdit() {
    final id = _editingId;
    if (id == null) return;
    final text = _editController.text.trim();
    if (text.isNotEmpty) _notifier.editAction(id, text: text).ignore();
    setState(() => _editingId = null);
  }

  void _onPromote(Action row, Action? current) {
    if (current == null) {
      _notifier.promotePlannedAction(row.id).ignore();
    } else {
      _confirmReplace(current: current, planned: row);
    }
  }

  Future<void> _confirmReplace({
    required Action current,
    required Action planned,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Replace current action?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _sheetLine('Current', current.actionText, _muted),
              const SizedBox(height: 8),
              _sheetLine('New', planned.actionText, _ink),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('plan_replace_confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                  ),
                  onPressed: () {
                    _notifier.supersedeAndPromote(planned.id).ignore();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Replace current action'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetLine(String label, String text, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: _muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(text, style: TextStyle(fontSize: 15, color: color)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    // AsyncValue.value retains the last data across a transient loading/error
    // (Riverpod stream refresh/re-subscribe), where .asData?.value would go
    // null. Keeping the Plan visible matters, and the retained `current` keeps
    // the promote decision routing through the 'Replace current action' confirm
    // instead of mis-firing a direct promote.
    final current = ref.watch(currentActionProvider(widget.outcomeId)).value;
    final planned =
        ref.watch(plannedActionsProvider(widget.outcomeId)).value ??
            const <Action>[];

    return Padding(
      key: const Key('plan_section'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.checklist_rounded, size: 16, color: _muted),
              const SizedBox(width: 8),
              const Text(
                'PLAN',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: _muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCurrentRow(current),
          if (planned.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildPlannedQueue(planned, current),
          ] else if (current == null) ...[
            const SizedBox(height: 8),
            const Text(
              "No plan yet — add the actions you're thinking of.",
              style: TextStyle(fontSize: 14, color: Color(0xFFD1D5DB)),
            ),
          ],
          const SizedBox(height: 8),
          _buildAddAffordance(),
        ],
      ),
    );
  }

  Widget _buildCurrentRow(Action? current) {
    if (current == null) {
      return const Padding(
        key: Key('plan_current_action'),
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No current action',
          style: TextStyle(fontSize: 15, color: _muted),
        ),
      );
    }
    return Container(
      key: const Key('plan_current_action'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.radio_button_checked, size: 18,
              color: Color(0xFF2563EB)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              current.actionText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
          ),
          IconButton(
            key: const Key('plan_demote_button'),
            icon: const Icon(Icons.arrow_downward, size: 18, color: _muted),
            tooltip: 'Move to plan',
            visualDensity: VisualDensity.compact,
            onPressed: () => _notifier.demoteCurrentAction(current.id).ignore(),
          ),
        ],
      ),
    );
  }

  Widget _buildPlannedQueue(List<Action> planned, Action? current) {
    return ReorderableListView(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      // onReorderItem already accounts for the removed item, so no manual
      // `newIndex -= 1` adjustment (unlike the deprecated onReorder).
      onReorderItem: (oldIndex, newIndex) {
        final ids = planned.map((a) => a.id).toList();
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        _notifier.reorderPlannedActions(ids).ignore();
      },
      children: [
        for (var i = 0; i < planned.length; i++)
          _buildPlannedRow(planned[i], i, current),
      ],
    );
  }

  Widget _buildPlannedRow(Action row, int index, Action? current) {
    final editing = _editingId == row.id;
    return Padding(
      key: Key('planned_action_${row.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              key: Key('plan_drag_handle'),
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.drag_indicator, size: 18, color: _muted),
            ),
          ),
          Expanded(
            child: editing
                ? TextField(
                    key: const Key('plan_edit_field'),
                    controller: _editController,
                    focusNode: _editFocus,
                    style: const TextStyle(fontSize: 15, color: _ink),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _commitEdit(),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _startEdit(row),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        row.actionText,
                        style: const TextStyle(fontSize: 15, color: _ink),
                      ),
                    ),
                  ),
          ),
          IconButton(
            key: Key('plan_promote_${row.id}'),
            icon: const Icon(Icons.arrow_upward, size: 18, color: _muted),
            tooltip: 'Make current',
            visualDensity: VisualDensity.compact,
            onPressed: () => _onPromote(row, current),
          ),
          IconButton(
            key: Key('plan_remove_${row.id}'),
            icon: const Icon(Icons.close, size: 18, color: _muted),
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            onPressed: () => _notifier.removePlannedAction(row.id).ignore(),
          ),
        ],
      ),
    );
  }

  Widget _buildAddAffordance() {
    if (_adding) {
      return TextField(
        key: const Key('plan_add_field'),
        controller: _addController,
        focusNode: _addFocus,
        autofocus: true,
        style: const TextStyle(fontSize: 15, color: _ink),
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 6),
          border: InputBorder.none,
          hintText: 'Add planned action',
          hintStyle: TextStyle(color: Color(0xFFD1D5DB)),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submitAdd(),
        onTapOutside: (_) => _submitAdd(),
      );
    }
    return InkWell(
      key: const Key('plan_add_trigger'),
      onTap: () => setState(() => _adding = true),
      borderRadius: BorderRadius.circular(8),
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.add, size: 18, color: Color(0xFF2563EB)),
            SizedBox(width: 8),
            Text(
              'Add planned action',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF2563EB),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
