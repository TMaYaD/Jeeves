/// A Habit's detail, edited where it sits. One widget serves the phone route
/// and the wide layout's right pane.
///
/// A new Habit is a draft held in memory. Nothing is written until it has a
/// title; then it is written once, in one transaction.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/daos/habit_dao.dart';
import '../../database/gtd_database.dart' show Habit, Tag;
import '../../models/habit_commitment.dart';
import '../../providers/clock_provider.dart';
import '../../providers/habit_actions_provider.dart';
import '../../providers/habit_progress_provider.dart';
import '../../providers/habits_provider.dart';
import '../../widgets/outcome_attribute_editors.dart';
import '../../widgets/project_picker.dart';
import 'habit_anchor_candidates.dart';
import 'habit_copy.dart';
import 'habit_flash_banner.dart';
import 'habit_routes.dart';
import 'habit_sheets.dart';

/// Banners already shown this session, so one shows once. Memory only.
final Set<String> _seenFlashKeys = {};

/// Labels chosen on a draft before the Habit exists.
final draftHabitLabelsProvider =
    NotifierProvider.autoDispose<_DraftLabels, List<Tag>>(_DraftLabels.new);

class _DraftLabels extends Notifier<List<Tag>> {
  @override
  List<Tag> build() => const [];
  void add(Tag tag) {
    if (state.every((t) => t.id != tag.id)) state = [...state, tag];
  }

  void remove(Tag tag) => state = [
    for (final t in state)
      if (t.id != tag.id) t,
  ];
}

/// Everything a draft holds before it is written.
class _Draft {
  String title = '';
  String? notes;
  String? energyLevel;
  int? estimateMinutes;
  HabitCommitmentDraft commitment = defaultNewHabitCommitment;
  HabitAnchorChoice anchor = const HabitAnchorChoice(HabitAnchorKind.none);
  Tag? area;
}

/// The Habit's detail. [habitId] null is a new draft.
class HabitDetailPane extends ConsumerStatefulWidget {
  const HabitDetailPane({
    super.key,
    required this.habitId,
    this.showNewBanner = false,
    this.embedded = false,
  });

  final String? habitId;
  final bool showNewBanner;

  /// True in the wide layout, where the pane has no app bar of its own.
  final bool embedded;

  @override
  ConsumerState<HabitDetailPane> createState() => _HabitDetailPaneState();
}

class _HabitDetailPaneState extends ConsumerState<HabitDetailPane> {
  final _draft = _Draft();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _titleFocus = FocusNode();
  final _notesFocus = FocusNode();
  HabitFlash? _flash;
  String _flashFacts = '';
  bool _titleSeeded = false;
  bool _draftWritten = false;
  List<Tag> _draftLabels = const [];
  late final HabitActions _habitActions;

  bool get _isDraft => widget.habitId == null;
  String get _today => habitDayKey(ref.read(clockProvider)());

  @override
  void initState() {
    super.initState();
    _habitActions = ref.read(habitActionsProvider);
    if (!_isDraft) {
      _titleFocus.addListener(() {
        if (!_titleFocus.hasFocus) _commitTitle();
      });
      _notesFocus.addListener(() {
        if (!_notesFocus.hasFocus) _commitNotes();
      });
      if (widget.showNewBanner && _seenFlashKeys.add('new:${widget.habitId}')) {
        _flash = HabitFlash.created;
      }
    }
  }

  @override
  void dispose() {
    // A focused field is not committed by its focus listener on teardown, and
    // a titled draft left in the wide pane has no Back to save it: write both.
    if (_isDraft) {
      unawaited(_writeDraft());
    } else if (_titleSeeded) {
      final id = widget.habitId!;
      unawaited(_habitActions.setTitle(id, _titleController.text));
      unawaited(_habitActions.setNotes(id, _notesController.text));
    }
    _titleController.dispose();
    _notesController.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  // --- writes ---------------------------------------------------------------

  Future<void> _commitTitle() async {
    final accepted = await _habitActions.setTitle(
      widget.habitId!,
      _titleController.text,
    );
    if (accepted) return;
    final habit = ref.read(habitByIdProvider(widget.habitId!)).value;
    if (habit != null) _titleController.text = habit.title;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(habitTitleEmptyMessage)));
    }
  }

  Future<void> _commitNotes() =>
      _habitActions.setNotes(widget.habitId!, _notesController.text);

  /// Writes the draft once, in one transaction. Returns the new Habit's id,
  /// or null when the title is empty or the draft was already written.
  Future<String?> _writeDraft() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || _draftWritten) return null;
    _draftWritten = true;
    final anchor = _draft.anchor;
    try {
      return await _habitActions.createFromDraft(
        HabitDraftValues(
          title: title,
          notes: _notesController.text,
          energyLevel: _draft.energyLevel,
          estimateMinutes: _draft.estimateMinutes,
          commitment: _draft.commitment,
          anchorKind: anchor.kind,
          anchorPartOfDay: anchor.partOfDay,
          anchorClockTime: anchor.clockTime,
          anchorHabitId: anchor.anchorHabitId,
          areaTagId: _draft.area?.id,
          labelTagIds: [for (final t in _draftLabels) t.id],
        ),
      );
    } catch (_) {
      _draftWritten = false;
      rethrow;
    }
  }

  Future<void> _submitDraftTitle() async {
    final id = await _writeDraft();
    if (id == null || !mounted) return;
    openHabitDetail(context, id, justCreated: true, replace: true);
  }

  // --- the view ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = _isDraft ? _buildDraft(context) : _buildExisting(context);
    if (widget.embedded) return body;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _isDraft) unawaited(_writeDraft());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.pop()),
          title: Text(_isDraft ? 'New Habit' : 'Habit'),
        ),
        body: body,
      ),
    );
  }

  Widget _buildDraft(BuildContext context) {
    final labels = ref.watch(draftHabitLabelsProvider);
    _draftLabels = labels;
    // A new Habit has no anchors yet, so no loop is possible: every active
    // Habit may be followed or preceded.
    final rows = ref.watch(habitListProvider).value ?? const [];
    return _fields(
      context,
      title: _draft.title,
      commitment: _draft.commitment,
      anchor: _draft.anchor,
      area: _draft.area,
      labels: labels,
      energy: _draft.energyLevel,
      estimate: _draft.estimateMinutes,
      state: HabitState.active,
      anchorTarget: null,
      candidates: [
        for (final row in rows)
          if (row.state == HabitState.active) row.habit,
      ],
    );
  }

  Widget _buildExisting(BuildContext context) {
    final id = widget.habitId!;
    final habit = ref.watch(habitByIdProvider(id)).value;
    final commitments = ref.watch(habitCommitmentsProvider(id)).value;
    final tags = ref.watch(habitTagsProvider(id)).value ?? const <Tag>[];
    final rows = ref.watch(habitListProvider).value ?? const [];
    final state = ref.watch(habitStateTodayProvider(id)) ?? HabitState.active;
    if (habit == null || commitments == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_titleSeeded) {
      _titleSeeded = true;
      _titleController.text = habit.title;
      _notesController.text = habit.notes ?? '';
    }
    final inForce =
        commitmentInForceOn(commitments, _today) ??
        (commitments.isEmpty ? null : commitments.last);
    final activeHabits = [
      for (final row in rows)
        if (row.state == HabitState.active) row.habit,
    ];
    final candidates = anchorCandidates(
      habit,
      [for (final r in rows) r.habit],
      {for (final h in activeHabits) h.id},
    );
    Habit? anchorTarget;
    HabitState? anchorTargetState;
    for (final row in rows) {
      if (row.habit.id == habit.anchorHabitId) {
        anchorTarget = row.habit;
        anchorTargetState = row.state;
      }
    }
    final anchorStopped =
        anchorTarget != null && anchorTargetState != HabitState.active;
    final flash = _flash ?? _derivedFlash(habit, anchorStopped, anchorTarget);
    return _fields(
      context,
      habit: habit,
      title: habit.title,
      commitment: inForce == null
          ? defaultNewHabitCommitment
          : habitDraftOf(inForce),
      anchor: HabitAnchorChoice(
        HabitAnchorKind.tryParse(habit.anchorKind) ?? HabitAnchorKind.none,
        partOfDay: habit.anchorPartOfDay,
        clockTime: habit.anchorClockTime,
        anchorHabitId: habit.anchorHabitId,
      ),
      area: tags.where((t) => t.type == habitAreaTagType).firstOrNull,
      labels: [
        for (final t in tags)
          if (habitLabelTagTypes.contains(t.type)) t,
      ],
      energy: habit.energyLevel,
      estimate: habit.timeEstimateMinutes,
      state: state,
      anchorTarget: anchorTarget,
      anchorStopped: anchorStopped,
      candidates: candidates,
      flash: flash,
    );
  }

  /// The banner a condition calls for when the detail is first opened.
  HabitFlash? _derivedFlash(Habit habit, bool anchorStopped, Habit? target) {
    if (anchorStopped &&
        _seenFlashKeys.add('anchor:${habit.id}:${target!.id}')) {
      _flashFacts = '${target.title} is no longer active.';
      return _flash = HabitFlash.anchorStopped;
    }
    final broken = ref
        .watch(habitProgressProvider(habit.id))
        ?.brokenStreakLength;
    if (broken != null && _seenFlashKeys.add('streak:${habit.id}:$broken')) {
      _flashFacts = 'A streak of $broken ended.';
      return _flash = HabitFlash.streakBroken;
    }
    return null;
  }

  Widget _fields(
    BuildContext context, {
    Habit? habit,
    required String title,
    required HabitCommitmentDraft commitment,
    required HabitAnchorChoice anchor,
    required Tag? area,
    required List<Tag> labels,
    required String? energy,
    required int? estimate,
    required HabitState state,
    required Habit? anchorTarget,
    bool anchorStopped = false,
    required List<Habit> candidates,
    HabitFlash? flash,
  }) {
    final theme = Theme.of(context);
    final isDraft = habit == null;
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        if (flash != null)
          HabitFlashBanner(
            text: habitFlashText(
              flash,
              (habit?.id.hashCode ?? 0) + flash.index,
              _flashFacts,
            ),
            onDismissed: () => setState(() {
              _flash = null;
              _flashFacts = '';
            }),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: TextField(
            key: const Key('habit_title'),
            controller: _titleController,
            focusNode: _titleFocus,
            autofocus: isDraft,
            inputFormatters: [LengthLimitingTextInputFormatter(500)],
            textInputAction: TextInputAction.done,
            style: theme.textTheme.headlineSmall,
            decoration: const InputDecoration(
              hintText: 'Name the Habit',
              border: InputBorder.none,
            ),
            onChanged: isDraft ? (v) => _draft.title = v : null,
            onSubmitted: (_) => isDraft ? _submitDraftTitle() : _commitTitle(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const Key('habit_notes'),
            controller: _notesController,
            focusNode: _notesFocus,
            minLines: 1,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Notes',
              border: InputBorder.none,
            ),
          ),
        ),
        const Divider(),
        _FieldRow(
          rowKey: const Key('habit_row_checkin'),
          label: 'Check-in',
          value: habitCheckInSummary(commitment),
          onTap: () async {
            final next = await showCheckInKindSheet(
              context,
              commitment,
              appliesNote: isDraft ? null : _appliesNote(commitment, false),
            );
            if (next != null) await _setCommitment(habit, next);
          },
        ),
        _FieldRow(
          rowKey: const Key('habit_row_repeat'),
          label: 'Repeat',
          value: habitRepeatSummary(commitment),
          onTap: () async {
            final next = await showRepeatSheet(
              context,
              commitment,
              appliesNote: isDraft ? null : _appliesNote(commitment, true),
            );
            if (next != null) await _setCommitment(habit, next);
          },
        ),
        _FieldRow(
          rowKey: const Key('habit_row_anchor'),
          label: 'Anchor',
          value: _anchorText(anchor, anchorTarget),
          onTap: () => _editAnchor(habit, anchor, candidates),
        ),
        if (anchorStopped)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${anchorTarget!.title} is paused or archived.',
                    key: const Key('habit_anchor_stopped_note'),
                  ),
                ),
                TextButton(
                  key: const Key('habit_choose_new_anchor'),
                  onPressed: () => _editAnchor(habit, anchor, candidates),
                  child: const Text('Choose a new anchor'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: ProjectPickerWidget(
            key: const Key('habit_area_picker'),
            tagType: 'area',
            currentTag: area,
            onAssign: (tag) => _setArea(habit, tag),
            onClear: () => _setArea(habit, null),
          ),
        ),
        _FieldRow(
          rowKey: const Key('habit_row_labels'),
          label: 'Labels',
          value: labels.isEmpty ? 'None' : labels.map((t) => t.name).join(', '),
          onTap: () => _editLabels(habit),
        ),
        _FieldRow(
          rowKey: const Key('habit_row_energy'),
          label: 'Energy',
          value: energy ?? 'Not set',
          onTap: () => showOutcomeEnergyLevelSheet(
            context,
            current: energy,
            onSet: (v) => _setEnergy(habit, v),
            onClear: () => _setEnergy(habit, null),
          ),
        ),
        _FieldRow(
          rowKey: const Key('habit_row_estimate'),
          label: 'Time estimate',
          value: estimate == null ? 'Not set' : '$estimate min',
          onTap: () => showOutcomeTimeEstimateSheet(
            context,
            null,
            current: estimate,
            showTimeboxedSwitch: false,
            onSaveEstimate: (minutes) => _setEstimate(habit, minutes),
          ),
        ),
        if (!isDraft) ..._actions(context, habit, state),
      ],
    );
  }

  String _anchorText(HabitAnchorChoice anchor, Habit? target) {
    switch (anchor.kind) {
      case HabitAnchorKind.none:
        return 'None';
      case HabitAnchorKind.partOfDay:
        return anchor.partOfDay ?? 'None';
      case HabitAnchorKind.clockTime:
        return 'At ${anchor.clockTime}';
      case HabitAnchorKind.afterHabit:
        return 'After ${target?.title ?? 'another Habit'}';
      case HabitAnchorKind.beforeHabit:
        return 'Before ${target?.title ?? 'another Habit'}';
    }
  }

  /// "Applies from today / this week / this month; earlier days keep their
  /// commitment", naming the period of the rule being edited.
  String _appliesNote(HabitCommitmentDraft commitment, bool repeat) {
    final period = switch (commitment.repeatKind) {
      HabitRepeatKind.timesPerWeek => 'this week',
      HabitRepeatKind.timesPerMonth => 'this month',
      _ => 'today',
    };
    return 'Applies from $period; earlier days keep their commitment.';
  }

  Future<void> _setCommitment(Habit? habit, HabitCommitmentDraft next) async {
    if (habit == null) {
      setState(() => _draft.commitment = next);
      return;
    }
    await _habitActions.setCommitment(habit.id, next);
  }

  Future<void> _editAnchor(
    Habit? habit,
    HabitAnchorChoice current,
    List<Habit> candidates,
  ) async {
    final next = await showAnchorSheet(
      context,
      current: current,
      candidates: candidates,
    );
    if (next == null) return;
    if (habit == null) {
      setState(() => _draft.anchor = next);
      return;
    }
    await _habitActions.setAnchor(
      habit.id,
      kind: next.kind,
      partOfDay: next.partOfDay,
      clockTime: next.clockTime,
      anchorHabitId: next.anchorHabitId,
    );
  }

  Future<void> _setArea(Habit? habit, Tag? tag) async {
    if (habit == null) {
      if (!mounted) return;
      setState(() => _draft.area = tag);
      return;
    }
    await _habitActions.setArea(habit.id, tag?.id);
  }

  void _editLabels(Habit? habit) {
    if (habit == null) {
      showLabelEditorSheet(
        context,
        title: 'Labels',
        cloudOnly: true,
        watchAssignedTags: (ref) => ref.watch(draftHabitLabelsProvider),
        onAssign: (ref, tag) =>
            ref.read(draftHabitLabelsProvider.notifier).add(tag),
        onRemove: (ref, tag) =>
            ref.read(draftHabitLabelsProvider.notifier).remove(tag),
      );
      return;
    }
    showLabelEditorSheet(
      context,
      title: 'Labels',
      cloudOnly: true,
      watchAssignedTags: (ref) => [
        for (final t
            in ref.watch(habitTagsProvider(habit.id)).value ?? const <Tag>[])
          if (habitLabelTagTypes.contains(t.type)) t,
      ],
      onAssign: (ref, tag) => _habitActions.assignLabel(habit.id, tag.id),
      onRemove: (ref, tag) => _habitActions.unassignLabel(habit.id, tag.id),
    );
  }

  Future<void> _setEnergy(Habit? habit, String? level) async {
    if (habit == null) {
      setState(() => _draft.energyLevel = level);
      return;
    }
    await _habitActions.setEnergy(habit.id, level);
  }

  Future<void> _setEstimate(Habit? habit, int? minutes) async {
    if (habit == null) {
      setState(() => _draft.estimateMinutes = minutes);
      return;
    }
    await _habitActions.setEstimate(habit.id, minutes);
  }

  // --- pause / archive --------------------------------------------------------

  List<Widget> _actions(BuildContext context, Habit habit, HabitState state) {
    Future<void> run(
      Future<void> Function() write,
      HabitFlash? flash,
      String facts,
    ) async {
      await write();
      if (!mounted) return;
      setState(() {
        _flash = flash;
        _flashFacts = facts;
      });
    }

    return [
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          children: [
            if (state == HabitState.active)
              OutlinedButton(
                key: const Key('habit_pause'),
                onPressed: () async {
                  final choice = await showPauseSheet(
                    context,
                    today: habitDateFromDayKey(_today)!,
                  );
                  if (choice == null) return;
                  await run(
                    () => _habitActions.pause(habit.id, resumesOn: choice.resumesOn),
                    HabitFlash.paused,
                    choice.resumesOn == null
                        ? 'Until you resume it.'
                        : 'Resumes on ${choice.resumesOn}.',
                  );
                },
                child: const Text('Pause'),
              ),
            if (state == HabitState.paused)
              OutlinedButton(
                key: const Key('habit_resume'),
                onPressed: () => run(
                  () => _habitActions.resume(habit.id),
                  null,
                  '',
                ),
                child: const Text('Resume'),
              ),
            if (state != HabitState.archived)
              OutlinedButton(
                key: const Key('habit_archive'),
                onPressed: () => run(
                  () => _habitActions.archive(habit.id),
                  HabitFlash.archived,
                  'Its Check-ins are kept. Restore it any time.',
                ),
                child: const Text('Archive'),
              ),
            if (state == HabitState.archived)
              OutlinedButton(
                key: const Key('habit_restore'),
                onPressed: () => run(
                  () => _habitActions.restore(habit.id),
                  null,
                  '',
                ),
                child: const Text('Restore'),
              ),
          ],
        ),
      ),
    ];
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.rowKey,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final Key rowKey;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    key: rowKey,
    title: Text(label),
    trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium),
    onTap: onTap,
  );
}

/// The detail as its own route on a phone.
class HabitDetailScreen extends StatelessWidget {
  const HabitDetailScreen({
    super.key,
    required this.habitId,
    this.justCreated = false,
  });

  final String? habitId;
  final bool justCreated;

  @override
  Widget build(BuildContext context) =>
      HabitDetailPane(habitId: habitId, showNewBanner: justCreated);
}
