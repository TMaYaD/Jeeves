/// Standalone clarify screen for a single inbox item.
///
/// Opened when the user taps an inbox row outside of a planning session.
/// Provides the same clarification UI (title, notes, energy level, time
/// estimate, due date, GTD routing buttons) as the planning wizard's
/// _ClarifyCard, but operates independently — it loads its own todo,
/// writes directly to the DAOs, and pops when the user routes the item.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../widgets/clarify_shared_widgets.dart';
import '../../widgets/person_tag_picker.dart';

class InboxClarifyScreen extends ConsumerStatefulWidget {
  const InboxClarifyScreen({super.key, required this.todoId});

  final String todoId;

  @override
  ConsumerState<InboxClarifyScreen> createState() => _InboxClarifyScreenState();
}

class _InboxClarifyScreenState extends ConsumerState<InboxClarifyScreen> {
  late TextEditingController _titleCtrl;
  late TextEditingController _notesCtrl;
  String? _energyLevel;
  int? _timeEstimate;
  DateTime? _dueDate;
  bool _processing = false;
  bool _loading = true;
  Todo? _todo;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _loadTodo();
  }

  Future<void> _loadTodo() async {
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    try {
      final todo = await db.todoDao.getTodo(widget.todoId, userId);
      if (!mounted) return;
      if (todo == null) {
        context.pop();
        return;
      }
      setState(() {
        _todo = todo;
        _titleCtrl.text = todo.title;
        _notesCtrl.text = todo.notes ?? '';
        _energyLevel = todo.energyLevel;
        _timeEstimate = todo.timeEstimate;
        // Storage is UTC; show calendar day in local timezone.
        _dueDate = todo.dueDate?.toLocal();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load item. Please try again.')),
        );
        context.pop();
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Operation failed. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// Writes editable fields to the DB. Returns false (blocking routing) when
  /// the title is empty.
  Future<bool> _saveFields() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) return false;
    final notes = _notesCtrl.text.trim();
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    final todo = _todo;
    if (todo == null) return false;
    await db.todoDao.updateFields(
      widget.todoId,
      userId,
      title: title,
      notes: notes.isNotEmpty ? notes : null,
      energyLevel: _energyLevel,
      timeEstimate: _timeEstimate,
      dueDate: _dueDate != null
          ? DateTime.utc(_dueDate!.year, _dueDate!.month, _dueDate!.day)
          : null,
      clearDueDate: _dueDate == null && todo.dueDate != null,
    );
    return true;
  }

  Future<void> _process() async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.inboxDao.processInboxItem(widget.todoId, userId: userId);
    if (mounted) context.pop();
  }

  Future<void> _processToMaybe() async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.inboxDao
        .processInboxItem(widget.todoId, userId: userId, intent: 'maybe');
    if (mounted) context.pop();
  }

  Future<void> _processToDone() async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    final db = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    await db.todoDao.markDone(widget.todoId, userId);
    if (mounted) context.pop();
  }

  Future<void> _processToWaitingFor() async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    await showPersonTagPicker(
      context,
      todoId: widget.todoId,
      assignedPersonTagIds: const {},
      requireSelection: true,
      onAfterConfirm: () async {
        if (!mounted) return;
        try {
          final db = ref.read(databaseProvider);
          final userId = ref.read(currentUserIdProvider);
          await db.inboxDao.processInboxItem(widget.todoId, userId: userId);
          if (mounted) context.pop();
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Operation failed. Please try again.')),
            );
          }
        }
      },
    );
  }

  Future<DateTime?> _pickDate() {
    final now = DateTime.now();
    return showDatePicker(
      context: context,
      initialDate: _dueDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Set due date',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Clarify'),
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // Clarifying question prompt
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

                // Title
                TextField(
                  key: const Key('clarify_title'),
                  controller: _titleCtrl,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  minLines: 1,
                ),
                const SizedBox(height: 12),

                // Notes
                TextField(
                  key: const Key('clarify_notes'),
                  controller: _notesCtrl,
                  decoration: InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'Context, desired outcome, dependencies…',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 4,
                  minLines: 2,
                ),
                const SizedBox(height: 20),

                // Energy level
                const ClarifyFieldLabel('ENERGY LEVEL'),
                const SizedBox(height: 8),
                ClarifyEnergyPicker(
                  selected: _energyLevel,
                  onSelect: (level) => setState(() => _energyLevel = level),
                ),
                const SizedBox(height: 20),

                // Time estimate
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
                      onTap: () =>
                          setState(() => _timeEstimate = selected ? null : m),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 20),

                // Due date
                const ClarifyFieldLabel('DUE DATE'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await _pickDate();
                        if (picked != null && mounted) {
                          setState(() => _dueDate = picked);
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
                        onPressed: () => setState(() => _dueDate = null),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 28),

                // Destination buttons — dimmed while a write is in flight.
                AnimatedOpacity(
                  opacity: _processing ? 0.4 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const ClarifyFieldLabel('PROCESS TO'),
                      const SizedBox(height: 12),
                      ClarifyDestinationButton(
                        label: 'Next Action',
                        icon: Icons.check_circle_outline,
                        color: const Color(0xFF16A34A),
                        enabled: !_processing,
                        onTap: () => _runAction(_process),
                      ),
                      const SizedBox(height: 8),
                      ClarifyDestinationButton(
                        label: 'Waiting For',
                        icon: Icons.hourglass_empty,
                        color: const Color(0xFFF59E0B),
                        enabled: !_processing,
                        onTap: () => _runAction(_processToWaitingFor),
                      ),
                      const SizedBox(height: 8),
                      ClarifyDestinationButton(
                        label: 'Maybe',
                        icon: Icons.star_border,
                        color: const Color(0xFF6B7280),
                        enabled: !_processing,
                        onTap: () => _runAction(_processToMaybe),
                      ),
                      const SizedBox(height: 8),
                      ClarifyDestinationButton(
                        label: 'Done (discard)',
                        icon: Icons.delete_outline,
                        color: const Color(0xFFDC2626),
                        enabled: !_processing,
                        onTap: () => _runAction(_processToDone),
                      ),
                      const SizedBox(height: 20),
                      ClarifyDestinationButton(
                        label: 'Skip',
                        icon: Icons.next_plan_outlined,
                        color: const Color(0xFF6B7280),
                        enabled: !_processing,
                        onTap: () => context.pop(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
