/// Shared clarification card UI extracted from the daily-planning ritual's
/// inbox-clarify step so the periodic-review wizard can render the same UI.
///
/// The card autosaves attribute edits (title / notes / energy / time / due)
/// directly to [TodoDao]; routing actions are delegated to the canonical
/// [ProcessToHandlers] action bar, which owns its own DAO writes. Per-flow
/// nav side-effects (recording routing history, advancing the cursor) are
/// wired through [onAfterRoute].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'process_to_handlers.dart';

/// Shared clarification card. Renders an editable view of [todoId] plus the
/// canonical "process to" action bar. Title/notes/energy/time/due autosave
/// directly via [TodoDao]; routing buttons drive [ProcessToHandlers].
class InboxClarifyCard extends ConsumerStatefulWidget {
  const InboxClarifyCard({
    super.key,
    required this.todoId,
    this.lastAction,
    this.onAfterRoute,
  });

  final String todoId;

  /// The action most recently applied to this item — drives the
  /// "previously selected" affordance on the matching destination button.
  final ProcessAction? lastAction;

  /// Called once after a successful route. Used for callsite-specific
  /// concerns like advancing the inbox cursor and recording routing history.
  final Future<void> Function(ProcessAction action)? onAfterRoute;

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

    // Title is required to route to anything except Trash. Disable the
    // four committed routes; Trash stays enabled so the user can throw away
    // an unnamed item.
    final disabled = _titleIsBlank
        ? const <ProcessAction>{
            ProcessAction.next,
            ProcessAction.waitingFor,
            ProcessAction.someday,
            ProcessAction.done,
          }
        : const <ProcessAction>{};

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

        const ClarifyFieldLabel('PROCESS TO'),
        const SizedBox(height: 12),
        ProcessToHandlers(
          todo: todo,
          disabled: disabled,
          // Opt out of the default-on `nextActionDialog` modifier: inbox
          // clarification supplies the phrase via the title-as-action
          // coupling below, so tapping Next should route immediately
          // rather than popping the dialog.
          except: const {ProcessAction.nextActionDialog},
          lastAction: widget.lastAction,
          onAfterRoute: (action) async {
            // Make sure title/notes are persisted before yielding to the
            // caller's nav handler — the inbox cursor advance reads the
            // recorded routing on the next item.
            await _flushTextSave();
            // Inbox-clarify title-as-action coupling: when the user routes
            // to Next Action or Waiting For from the inbox, mirror the
            // current title into `next_action_text` so the new row leaves
            // inbox with a defined action. The controller's live value
            // wins over the (possibly debounced) todos.title column so a
            // fast typer's edit isn't lost. With the dialog modifier
            // excepted, the inbox Next button always reports plain `next`.
            if (action == ProcessAction.next ||
                action == ProcessAction.waitingFor) {
              final title = _titleCtrl?.text.trim() ?? '';
              if (title.isNotEmpty) {
                await ref
                    .read(databaseProvider)
                    .todoDao
                    .setNextActionText(widget.todoId, title);
              }
            }
            await widget.onAfterRoute?.call(action);
          },
        ),
      ],
    );
  }
}
