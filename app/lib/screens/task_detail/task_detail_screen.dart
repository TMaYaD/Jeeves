import 'dart:async';

// The Drift `Action` row type (issue #475) collides with Material's
// `Action<Intent>` widget class; this screen uses no Material `Action`, so hide
// it and keep the domain type.
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/daos/action_dao.dart' show TerminatedAction;
import '../../database/gtd_database.dart';
import '../../providers/focus_session_provider.dart';
import '../../providers/sprint_timer_provider.dart' show sprintTimerProvider;
import '../../providers/task_detail_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../../widgets/async_subject.dart';
import '../../widgets/meta_chip.dart';
import '../../widgets/outcome_attribute_editors.dart';
import '../../widgets/outcome_attribute_strip.dart';
import '../../widgets/outcome_plan_section.dart';
import '../../widgets/person_tag_picker.dart';
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

  /// The writer, captured while the element is still mounted so [dispose] can
  /// issue the pending-edit flush.
  ///
  /// `dispose()` cannot reach it through `ref`: `StatefulElement.unmount()`
  /// marks the element defunct — so `context.mounted` goes false — *before* it
  /// calls `state.dispose()`, and Riverpod's `ref` asserts on exactly that
  /// (#529). Note that `State.mounted` is still **true** in there, because
  /// `state._element` is nulled only afterwards, so the `mounted` guards on the
  /// two focus listeners protect nothing during teardown.
  ///
  /// The notifier rather than the raw database: [taskDetailNotifierProvider]
  /// captures `db` and `userId` eagerly and documents that holding it past its
  /// `autoDispose` ref is safe, so the flush routes through the same
  /// `updateTitle` / `updateNotes` the listeners use and cannot drift from
  /// them. Every other read in this State runs while mounted and keeps going
  /// through `ref` — see [_notifier].
  late final TaskDetailNotifier _notifierForDisposeFlush;

  bool _titleInitialized = false;
  bool _notesInitialized = false;
  bool _isEditingNotes = false;

  /// What the fields were last reconciled against — seeded from the row, or
  /// written back to it. The flush writes only what differs from them.
  ///
  /// Suppressing a redundant write is mandatory, not hygiene: [TodoDao.updateFields]
  /// stamps `updated_at` unconditionally, stamps `last_clarified_at` on any
  /// mutation, and authors a sync op, so an unconditional flush would restamp
  /// clarification and bump sync arbitration on every exit from this screen.
  ///
  /// Held in the form the DAO stores: trimmed for both, because `updateTitle`
  /// and `updateNotes` both trim (#705). An emptied notes field therefore
  /// baselines as `''`, which is the same `''` the seed uses for a NULL
  /// column — so a clear is not re-issued by the flush.
  String? _baselineTitle;
  String? _baselineNotes;

  @override
  void initState() {
    super.initState();
    _notifierForDisposeFlush =
        ref.read(taskDetailNotifierProvider(widget.todoId));
    _titleController = TextEditingController();
    _notesController = TextEditingController();

    _titleFocusNode = FocusNode();
    _notesFocusNode = FocusNode();

    _titleFocusNode.addListener(() {
      if (!_titleFocusNode.hasFocus && mounted) {
        _saveTitle(_titleController.text);
      }
    });

    _notesFocusNode.addListener(() {
      if (!_notesFocusNode.hasFocus && mounted) {
        setState(() {
          _isEditingNotes = false;
        });
        _saveNotes(_notesController.text);
      }
    });
  }

  /// Writes the title and moves its baseline. The baseline moves as the write
  /// is *issued*, not when it lands: the flush is a backstop for the case where
  /// the save trigger never fires, not a retry for one that fired and failed —
  /// a failure is reported the same way it always was, on the console.
  void _saveTitle(String title) {
    _baselineTitle = title.trim();
    _notifier
        .updateTitle(title)
        .catchError((e) {
          debugPrint('Error saving title: $e');
          return false;
        });
  }

  void _saveNotes(String notes) {
    _baselineNotes = notes.trim();
    _notifier
        .updateNotes(notes)
        .catchError((e) {
          debugPrint('Error saving notes: $e');
          return false;
        });
  }

  @override
  void dispose() {
    _flushPendingTextEdits();
    _titleFocusNode.dispose();
    _notesFocusNode.dispose();
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// The last line of defence for a title or notes edit still in the field when
  /// the screen goes.
  ///
  /// Focus loss stays the primary trigger (ADR-0023); this only puts a floor
  /// under it. A route pop saves today because the newly-current route hands
  /// focus over while the popped subtree is still mounted, so the listener
  /// fires normally — but that is framework behaviour this screen does not own,
  /// and its failure mode is a silent, unlogged lost edit.
  ///
  /// Deliberately adds no rules of its own: it does exactly what focus loss
  /// would have done, including writing a blank title and — since #705 —
  /// nulling the column for an emptied notes field. Making the two exits
  /// disagree would be new, undocumented behaviour.
  ///
  /// No `ref.read` / `ref.watch` in here — see [_notifierForDisposeFlush].
  void _flushPendingTextEdits() {
    // A flush after the Outcome was deleted is dropped by the notifier's
    // write guard (#447).
    final notifier = _notifierForDisposeFlush;
    // Snapshot the text before anything is disposed. Guarded on the
    // initialisation latches too: a screen torn down while the subject was
    // still loading has no controller text worth trusting.
    if (_titleInitialized) {
      final title = _titleController.text;
      if (title.trim() != _baselineTitle) {
        // Fire-and-forget: the screen is gone, so there is no surface left to
        // tell the user on — the console is the same sink the focus-loss save
        // uses. Uncaught, a throwing DAO would escape as an unhandled async
        // error from teardown, which reads as a framework fault rather than a
        // lost edit.
        unawaited(notifier.updateTitle(title).catchError(
            (Object e) {
          debugPrint('TaskDetailScreen: title flush failed: $e');
          return false;
        }));
      }
    }
    if (_notesInitialized) {
      final notes = _notesController.text;
      if (notes.trim() != _baselineNotes) {
        unawaited(notifier.updateNotes(notes).catchError(
            (Object e) {
          debugPrint('TaskDetailScreen: notes flush failed: $e');
          return false;
        }));
      }
    }
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
            _baselineTitle = todo.title.trim();
            _titleInitialized = true;
          }
          if (!_notesInitialized) {
            _notesController.text = todo.notes ?? '';
            _baselineNotes = (todo.notes ?? '').trim();
            _notesInitialized = true;
          }

          final tags = tagsAsync.asData?.value ?? [];
          final projectTag = tags.where((t) => t.type == 'project').firstOrNull;
          final contextTags = tags.where((t) => t.type == 'context').toList();
          final personTags = tags.where((t) => t.type == 'person').toList();

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
                      if (tagsAsync.asData != null)
                        TaskStatusRow(todo: todo, tags: tags),
                      const SizedBox(height: 8),
                      // Title TextField (Show-mode styled)
                      TextField(
                        key: const Key('task_detail_title'),
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
                      OutcomeAttributeStrip(
                        energyLevel: todo.energyLevel,
                        timeEstimateMinutes: todo.timeEstimate,
                        dueDate: todo.dueDate,
                        onEnergyTap: () => showOutcomeEnergyLevelSheet(
                            context, _notifier, todo.energyLevel),
                        onEstimateTap: () => showOutcomeTimeEstimateSheet(
                            context, _notifier, todo.timeEstimate),
                        onDueTap: () async {
                          final picked = await pickOutcomeDueDate(context, todo.dueDate);
                          if (picked != null) {
                            unawaited(_notifier.setDueDate(picked));
                          }
                        },
                        onClearDue: () => unawaited(_notifier.clearDueDate()),
                      ),
                      const SizedBox(height: 16),
                      // Context Tags
                      TagList(
                        tags: contextTags,
                        spacing: 12,
                        runSpacing: 8,
                        onTap: (_) => showOutcomeContextTagEditor(context, widget.todoId),
                        trailing: GestureDetector(
                          onTap: () => showOutcomeContextTagEditor(context, widget.todoId),
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
                      const SizedBox(height: 16),
                      const Text(
                        'WAITING FOR',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                      const SizedBox(height: 6),
                      InkWell(
                        key: const Key('task_detail_delegates'),
                        onTap: () => showPersonTagPicker(
                          context,
                          todoId: widget.todoId,
                          assignedPersonTagIds:
                              personTags.map((t) => t.id).toSet(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            personTags.isEmpty
                                ? 'Nobody'
                                : (personTags.map((t) => t.name).toList()
                                      ..sort())
                                    .join(', '),
                            style: TextStyle(
                              fontSize: 14,
                              color: personTags.isEmpty
                                  ? const Color(0xFF9CA3AF)
                                  : const Color(0xFF374151),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
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
                              // Reminders to the bottom of the viewport.
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Plan section (planned queue) above Notes —
                                  // the Outcome's "what's next" (ADR-0004)
                                  // outranks free-text notes.
                                  OutcomePlanSection(outcomeId: widget.todoId),
                                  // History sits directly under the Plan so
                                  // the whole Action chain — what's next, and
                                  // what came before — reads in one place.
                                  _ActionHistorySection(
                                      outcomeId: widget.todoId),
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
                                            key: const Key('task_detail_notes'),
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
                                                              // Through the same helper the focus-loss
                                                              // save uses, so the baseline moves with
                                                              // it: a ticked checkbox is a notes write
                                                              // like any other, and leaving the
                                                              // baseline behind would have the dispose
                                                              // flush restate it.
                                                              _saveNotes(newNotes);
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
                              // Reminders and capture provenance (at the literal bottom of the viewport or content)
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

  /// The screen's chrome. The bar carries the read-only identity of
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

/// The Outcome's **history** (ADR-0001 story 8, issue #478): the chain of its
/// terminated Actions — what the user finished (`done` → "Done") and what they
/// abandoned before finishing (`superseded` → "Abandoned") — newest-first, with
/// the minutes logged against each.
///
/// Collapsed by default and hidden entirely when the Outcome has terminated no
/// Action (mirroring [_CapturedFromSection]), so a fresh or pre-epic Outcome
/// shows no empty shell.
///
/// **Read-only by construction.** A terminated Action is a record: it cannot be
/// edited, re-promoted, or deleted (ADR-0004). The rows are `Text`
/// and nothing else — no `IconButton`, no `GestureDetector`, no `TextField` —
/// so the guarantee is structural rather than a matter of remembering to leave
/// the affordances off. No successor link is rendered between a superseded
/// Action and whatever replaced it, because the model stores none.
class _ActionHistorySection extends ConsumerWidget {
  const _ActionHistorySection({required this.outcomeId});

  final String outcomeId;

  static const _muted = Color(0xFF9CA3AF);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(terminatedActionsProvider(outcomeId)).value ??
        const <TerminatedAction>[];
    if (history.isEmpty) return const SizedBox.shrink();

    final count = history.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Theme(
        // Strip the default divider lines, matching the flat section styling.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        // ExpansionTile renders a ListTile, which paints its ink splash on the
        // nearest Material ancestor; a transparency Material gives the tile its
        // own ink surface without painting over anything behind it.
        child: Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            key: const Key('action_history_section'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
            leading: const Icon(Icons.history, size: 18, color: _muted),
            title: Text(
              count == 1 ? 'History (1 action)' : 'History ($count actions)',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: Color(0xFF6B7280),
              ),
            ),
            children: [
              // Every interactive-descendant assertion is scoped to this
              // container: the tile header above owns one tap target (the
              // expander), which navigates rather than mutates.
              Column(
                key: const Key('action_history_rows'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in history) _historyRow(entry),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _historyRow(TerminatedAction entry) {
    final action = entry.action;
    return Padding(
      key: Key('history_action_${action.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            action.actionText,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF374151),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _terminalLabel(entry),
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
        ],
      ),
    );
  }

  /// `Done 2026-03-04` / `Abandoned 2026-03-02`, with ` · 25m` appended when the
  /// Action earned logged time.
  ///
  /// The verb is the user-facing half of the copy↔model mapping recorded in
  /// CONTEXT.md § Action: "Done" ↔ `role='done'`, "Abandoned" ↔
  /// `role='superseded'`. The date is the terminal timestamp — `done_at` for a
  /// completion, `updated_at` for a supersession (it has no column
  /// of its own), `created_at` for a row carrying neither — rendered local, the
  /// same shape the "Captured from…" section uses.
  static String _terminalLabel(TerminatedAction entry) {
    final action = entry.action;
    final verb = action.role == 'done' ? 'Done' : 'Abandoned';
    final at =
        (action.doneAt ?? action.updatedAt ?? action.createdAt).toLocal();
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    final minutes =
        entry.loggedMinutes > 0 ? ' · ${formatMinutesLabel(entry.loggedMinutes)}' : '';
    return '$verb $y-$m-$d$minutes';
  }
}
