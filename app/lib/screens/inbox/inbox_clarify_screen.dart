/// Standalone clarify screen for a single Inbox Capture.
///
/// Opened when the user taps an inbox row outside of a planning session.
/// Provides the same clarification UI (title, notes, energy level, time
/// estimate, due date, GTD routing buttons) as the planning wizard's
/// _ClarifyCard, but operates independently — it loads its own Capture,
/// delegates its writes to [ClarificationService], and pops when the user
/// clarifies the item.
///
/// Title and notes autosave onto the Capture. Energy, time estimate and due
/// date have no column on a Capture (ADR-0006) — they are held as draft state
/// here and written onto the Outcome that
/// [ClarificationService.clarifyCaptureToOutcome] creates.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../models/todo.dart' show RoutingKind;
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../services/clarification_service.dart';
import '../../widgets/clarify_shared_widgets.dart';
import '../../widgets/person_tag_picker.dart';

class InboxClarifyScreen extends ConsumerStatefulWidget {
  const InboxClarifyScreen({super.key, required this.captureId});

  final String captureId;

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
  Capture? _capture;

  static const _estimateOptions = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _loadCapture();
  }

  Future<void> _loadCapture() async {
    final db = ref.read(databaseProvider);
    try {
      final capture = await db.captureDao.getCapture(widget.captureId);
      if (!mounted) return;
      if (capture == null) {
        context.pop();
        return;
      }
      setState(() {
        _capture = capture;
        _titleCtrl.text = capture.title;
        _notesCtrl.text = capture.notes ?? '';
        // Energy / estimate / due start empty: a Capture carries none of them.
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

  /// Persists the Capture's text edits. Returns false (blocking the route)
  /// when the title is empty — an Outcome must be nameable.
  Future<bool> _saveFields() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a title')),
        );
      }
      return false;
    }
    final notes = _notesCtrl.text.trim();
    final capture = _capture;
    if (capture == null) return false;
    final hadNotes = (capture.notes ?? '').isNotEmpty;
    await ref.read(databaseProvider).captureDao.updateFields(
          widget.captureId,
          title: title,
          notes: notes.isNotEmpty ? notes : null,
          clearNotes: notes.isEmpty && hadNotes,
        );
    return true;
  }

  /// The Outcome-shaped attributes this card has collected. Applied by
  /// [ClarificationService.clarifyCaptureToOutcome] to the Outcome it mints.
  ({String title, String? notes, DateTime? dueDate}) get _draft => (
        title: _titleCtrl.text.trim(),
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        // Strip the time component: the picker collects a calendar day.
        dueDate: _dueDate != null
            ? DateTime(_dueDate!.year, _dueDate!.month, _dueDate!.day)
            : null,
      );

  /// Clarifies the Capture into a new Outcome routed to [to], carrying the
  /// draft attributes and any delegates.
  Future<void> _clarifyTo(
    RoutingKind to, {
    Set<String>? personTagIds,
  }) async {
    final draft = _draft;
    await ref.read(clarificationServiceProvider).clarifyCaptureToOutcome(
          widget.captureId,
          to: to,
          userId: ref.read(currentUserIdProvider),
          title: draft.title,
          notes: draft.notes,
          energyLevel: _energyLevel,
          timeEstimate: _timeEstimate,
          dueDate: draft.dueDate,
          // Title-as-action: a Capture is always a first clarification, so
          // there is no deliberate phrase to clobber. Consumed only for Next
          // and Waiting For.
          nextActionText: draft.title,
          personTagIds: personTagIds,
          tagIds: await ref
              .read(databaseProvider)
              .captureDao
              .tagHintIdsForCapture(widget.captureId),
        );
  }

  /// Shared flow for the one-tap routing handlers: persist field edits,
  /// bail if saving failed (empty title) or the screen unmounted, run the
  /// routing [action] against [ClarificationService], then pop.
  Future<void> _saveAndRoute(Future<void> Function() action) async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    await action();
    if (mounted) context.pop();
  }

  Future<void> _process() =>
      _saveAndRoute(() => _clarifyTo(RoutingKind.nextAction));

  Future<void> _processToMaybe() =>
      _saveAndRoute(() => _clarifyTo(RoutingKind.maybe));

  Future<void> _processToDone() =>
      _saveAndRoute(() => _clarifyTo(RoutingKind.done));

  Future<void> _processToWaitingFor() async {
    final saved = await _saveFields();
    if (!saved || !mounted) return;
    await showPersonTagPicker(
      context,
      // Selection-only: the Outcome does not exist yet, so the picker has
      // nothing to write to. clarifyCaptureToOutcome attaches the delegates to
      // the Outcome it creates, in the same transaction.
      assignedPersonTagIds: const {},
      requireSelection: true,
      onConfirmSelection: (selected) async {
        if (!mounted) return;
        try {
          await _clarifyTo(RoutingKind.waitingFor, personTagIds: selected);
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
