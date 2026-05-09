/// Shared clarification card UI extracted from the daily-planning ritual's
/// inbox-clarify step so the periodic-review wizard can render the same UI.
///
/// The card autosaves attribute edits (title / notes / energy / time / due)
/// directly to [TodoDao]; it never assumes the planning ritual's notifier or
/// re-clarification surface. Per-flow side-effects on routing (recording
/// history, advancing nav, capturing prior state) belong on the parent and
/// are wired through [onRoute].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'person_tag_picker.dart';

/// Shared clarification card. Renders an editable view of [todoId] plus the
/// five GTD destinations. Title/notes/energy/time/due autosave directly via
/// [TodoDao]; destination buttons fire [onRoute].
///
/// For [RoutingKind.waitingFor] the card opens a [PersonTagPickerSheet]
/// internally; [onRoute] fires only after the user confirms a person tag, so
/// the parent doesn't need to know about the picker.
class InboxClarifyCard extends ConsumerStatefulWidget {
  const InboxClarifyCard({
    super.key,
    required this.todoId,
    this.lastRouting,
    required this.onRoute,
  });

  final String todoId;

  /// The last routing applied to this item, or null. Drives the
  /// "previously selected" affordance on the matching destination button.
  final RoutingKind? lastRouting;

  /// Called after pending edits have flushed and any picker has confirmed.
  /// The callback performs the actual DAO routing call (and any flow-specific
  /// side effects).
  final Future<void> Function(RoutingKind kind) onRoute;

  @override
  ConsumerState<InboxClarifyCard> createState() => _InboxClarifyCardState();
}

class _InboxClarifyCardState extends ConsumerState<InboxClarifyCard> {
  TextEditingController? _titleCtrl;
  TextEditingController? _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;
  bool _initialised = false;
  bool _processing = false;
  // Mirrors `_titleCtrl.text.trim().isEmpty` for build-time gating of the
  // routing buttons. Updated synchronously in `_onTextChanged` so the user
  // sees the destination buttons (and the title's error state) react as
  // they type — without a SnackBar or other toast surface.
  bool _titleIsBlank = false;

  static const _textDebounceMs = 400;
  Timer? _textDebouncer;
  String? _lastSavedTitle;
  String? _lastSavedNotes;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  void _initialiseFrom(Todo todo) {
    if (_initialised) return;
    _initialised = true;
    _titleCtrl = TextEditingController(text: todo.title);
    _notesCtrl = TextEditingController(text: todo.notes ?? '');
    _lastSavedTitle = todo.title.trim();
    _lastSavedNotes = (todo.notes ?? '').trim();
    _titleIsBlank = todo.title.trim().isEmpty;
    _energyLevel = todo.energyLevel;
    _timeEstimate = todo.timeEstimate;
    _dueDate = todo.dueDate?.toLocal();
  }

  @override
  void dispose() {
    _textDebouncer?.cancel();
    unawaited(_flushTextSave());
    _titleCtrl?.dispose();
    _notesCtrl?.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final blank = (_titleCtrl?.text ?? '').trim().isEmpty;
    if (blank != _titleIsBlank) {
      setState(() => _titleIsBlank = blank);
    }
    _textDebouncer?.cancel();
    _textDebouncer = Timer(
      const Duration(milliseconds: _textDebounceMs),
      _flushTextSave,
    );
  }

  Future<void> _flushTextSave() async {
    _textDebouncer?.cancel();
    _textDebouncer = null;
    final trimmedTitle = (_titleCtrl?.text ?? '').trim();
    final trimmedNotes = (_notesCtrl?.text ?? '').trim();
    if (trimmedTitle.isEmpty) return;
    if (trimmedTitle == _lastSavedTitle && trimmedNotes == _lastSavedNotes) {
      return;
    }
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      title: trimmedTitle,
      notes: trimmedNotes,
    );
    _lastSavedTitle = trimmedTitle;
    _lastSavedNotes = trimmedNotes;
  }

  Future<void> _saveEnergy(String? level) async {
    if (level == null) return;
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(widget.todoId, energyLevel: level);
  }

  Future<void> _saveTimeEstimate(int? minutes) async {
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      timeEstimate: minutes,
      clearTimeEstimate: minutes == null,
    );
  }

  Future<void> _saveDueDate(DateTime? date, {required bool clear}) async {
    final db = ref.read(databaseProvider);
    await db.todoDao.updateFields(
      widget.todoId,
      dueDate: date,
      clearDueDate: clear,
    );
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// Flushes any pending text edit and returns true when the title is
  /// non-empty. The card refuses to route an item with an empty title.
  Future<bool> _flushAndValidate() async {
    await _flushTextSave();
    final title = _titleCtrl?.text.trim() ?? '';
    return title.isNotEmpty;
  }

  Future<void> _routeNextAction() async {
    if (!await _flushAndValidate()) return;
    await widget.onRoute(RoutingKind.nextAction);
  }

  Future<void> _routeWaitingFor(BuildContext context) async {
    if (!await _flushAndValidate()) return;
    if (!context.mounted) return;
    final db = ref.read(databaseProvider);
    final currentTagIds =
        await db.todoDao.getPersonTagIdsForTodo(widget.todoId);
    if (!context.mounted) return;
    await showPersonTagPicker(
      context,
      todoId: widget.todoId,
      assignedPersonTagIds: currentTagIds,
      requireSelection: true,
      onAfterConfirm: () async {
        if (!context.mounted) return;
        await widget.onRoute(RoutingKind.waitingFor);
      },
    );
  }

  Future<void> _routeMaybe() async {
    if (!await _flushAndValidate()) return;
    await widget.onRoute(RoutingKind.maybe);
  }

  Future<void> _routeDone() async {
    if (!await _flushAndValidate()) return;
    await widget.onRoute(RoutingKind.done);
  }

  Future<void> _routeTrash() async {
    // Discarding bypasses title validation — the user shouldn't have to name
    // an item just to throw it away.
    await _flushTextSave();
    await widget.onRoute(RoutingKind.trash);
  }

  Future<DateTime?> _pickDate(BuildContext context) {
    final now = DateTime.now();
    final candidate = _dueDate ?? now.add(const Duration(days: 1));
    final initial = candidate.isBefore(now) ? now : candidate;
    return showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Set due date',
    );
  }

  @override
  Widget build(BuildContext context) {
    final todoAsync = ref.watch(taskDetailTodoProvider(widget.todoId));
    final todo = todoAsync.value;
    if (todo == null) {
      return const Center(child: CircularProgressIndicator());
    }
    _initialiseFrom(todo);

    return ListView(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: const Row(
            children: [
              Icon(Icons.help_outline,
                  size: 18, color: Color(0xFF2563EB)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  "What's the expected outcome?",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1D4ED8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _titleCtrl,
          onChanged: (_) => _onTextChanged(),
          decoration: InputDecoration(
            labelText: 'Title',
            errorText: _titleIsBlank ? 'Title is required to process' : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          minLines: 1,
        ),
        const SizedBox(height: 12),

        TextField(
          controller: _notesCtrl,
          onChanged: (_) => _onTextChanged(),
          decoration: InputDecoration(
            labelText: 'Notes (optional)',
            hintText: 'Context, desired outcome, dependencies…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          textCapitalization: TextCapitalization.sentences,
          maxLines: 4,
          minLines: 2,
        ),
        const SizedBox(height: 20),

        const ClarifyFieldLabel('ENERGY LEVEL'),
        const SizedBox(height: 8),
        ClarifyEnergyPicker(
          selected: _energyLevel,
          onSelect: (level) {
            setState(() => _energyLevel = level);
            unawaited(_saveEnergy(level));
          },
        ),
        const SizedBox(height: 20),

        const ClarifyFieldLabel('TIME ESTIMATE'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _estimateOptions.map((m) {
            final selected = _timeEstimate == m;
            return ClarifyEstimateChip(
              label: m < 60
                  ? '${m}m'
                  : m % 60 == 0
                      ? '${m ~/ 60}h'
                      : '${m ~/ 60}h ${m % 60}m',
              selected: selected,
              onTap: () {
                final newValue = selected ? null : m;
                setState(() => _timeEstimate = newValue);
                unawaited(_saveTimeEstimate(newValue));
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 20),

        const ClarifyFieldLabel('DUE DATE'),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                final picked = await _pickDate(context);
                if (picked != null && context.mounted) {
                  setState(() => _dueDate = picked);
                  unawaited(_saveDueDate(picked, clear: false));
                }
              },
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                _dueDate != null
                    ? '${_dueDate!.year}-'
                        '${_dueDate!.month.toString().padLeft(2, '0')}-'
                        '${_dueDate!.day.toString().padLeft(2, '0')}'
                    : 'Set date',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _dueDate != null
                    ? const Color(0xFF2563EB)
                    : const Color(0xFF6B7280),
              ),
            ),
            if (_dueDate != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey[400],
                tooltip: 'Clear date',
                onPressed: () {
                  setState(() => _dueDate = null);
                  unawaited(_saveDueDate(null, clear: true));
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 28),

        AnimatedOpacity(
          opacity: _processing ? 0.4 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ClarifyFieldLabel('PROCESS TO'),
              const SizedBox(height: 12),
              // Routing destinations except Discard require a title — disabling
              // them mirrors the validation the routing methods enforce, so
              // the user gets visual feedback rather than a silent no-op.
              ClarifyDestinationButton(
                label: 'Next Action',
                icon: Icons.check_circle_outline,
                color: const Color(0xFF2563EB),
                enabled: !_processing && !_titleIsBlank,
                isPreviouslySelected:
                    widget.lastRouting == RoutingKind.nextAction,
                onTap: () => _runAction(_routeNextAction),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Waiting For',
                icon: Icons.person_outlined,
                color: const Color(0xFF7C3AED),
                enabled: !_processing && !_titleIsBlank,
                isPreviouslySelected:
                    widget.lastRouting == RoutingKind.waitingFor,
                onTap: () => _runAction(() => _routeWaitingFor(context)),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Maybe',
                icon: Icons.star_border,
                color: const Color(0xFF6B7280),
                enabled: !_processing && !_titleIsBlank,
                isPreviouslySelected:
                    widget.lastRouting == RoutingKind.maybe,
                onTap: () => _runAction(_routeMaybe),
              ),
              const SizedBox(height: 8),
              ClarifyDestinationButton(
                label: 'Done',
                icon: Icons.task_alt_outlined,
                color: const Color(0xFF16A34A),
                enabled: !_processing && !_titleIsBlank,
                isPreviouslySelected:
                    widget.lastRouting == RoutingKind.done,
                onTap: () => _runAction(_routeDone),
              ),
              const SizedBox(height: 8),
              // Discard intentionally bypasses title validation — a user
              // shouldn't have to name an item just to throw it away.
              ClarifyDestinationButton(
                label: 'Discard',
                icon: Icons.delete_outline,
                color: const Color(0xFFDC2626),
                enabled: !_processing,
                isPreviouslySelected:
                    widget.lastRouting == RoutingKind.trash,
                onTap: () => _runAction(_routeTrash),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
