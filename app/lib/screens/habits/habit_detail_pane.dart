/// A Habit's detail, edited where it sits. One widget serves the phone route
/// and the wide layout's right pane.
///
/// A new Habit is a draft held in memory. Nothing is written until it has a
/// title; then it is written once, in one transaction.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/daos/habit_dao.dart';
import '../../database/gtd_database.dart' show Habit, Tag;
import '../../models/estimate.dart';
import '../../models/habit_commitment.dart';
import '../../providers/auth_provider.dart';
import '../../providers/clock_provider.dart';
import '../../providers/database_provider.dart';
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
  bool _saving = false;

  bool get _isDraft => widget.habitId == null;
  String get _userId => ref.read(currentUserIdProvider);
  DateTime get _now => ref.read(clockProvider)();
  String get _today => habitDayKey(_now);
  HabitDao get _dao => ref.read(databaseProvider).habitDao;

  @override
  void initState() {
    super.initState();
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
    _titleController.dispose();
    _notesController.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  // --- writes ---------------------------------------------------------------

  Future<void> _updateDetails(
    Habit habit, {
    String? title,
    Object? notes = _keep,
    Object? energy = _keep,
    Object? estimate = _keep,
  }) {
    return _dao.updateHabitDetails(
      habitId: habit.id,
      userId: _userId,
      title: title ?? habit.title,
      notes: identical(notes, _keep) ? habit.notes : notes as String?,
      energyLevel: identical(energy, _keep)
          ? habit.energyLevel
          : energy as String?,
      timeEstimateMinutes: identical(estimate, _keep)
          ? habit.timeEstimateMinutes
          : estimate as int?,
      now: _now,
    );
  }

  Future<void> _commitTitle() async {
    final habit = ref.read(habitByIdProvider(widget.habitId!)).value;
    if (habit == null) return;
    final text = _titleController.text.trim();
    if (text == habit.title) return;
    if (text.isEmpty) {
      _titleController.text = habit.title;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(habitTitleEmptyMessage)));
      }
      return;
    }
    await _updateDetails(habit, title: text);
  }

  Future<void> _commitNotes() async {
    final habit = ref.read(habitByIdProvider(widget.habitId!)).value;
    if (habit == null) return;
    final text = _notesController.text.trim();
    final notes = text.isEmpty ? null : text;
    if (notes == habit.notes) return;
    await _updateDetails(habit, notes: notes);
  }

  /// Writes the draft in one transaction. Returns the new Habit's id, or null
  /// when the title is still empty.
  Future<String?> _saveDraft() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || _saving) return null;
    _saving = true;
    final db = ref.read(databaseProvider);
    final labels = ref.read(draftHabitLabelsProvider);
    final userId = _userId;
    final now = _now;
    final today = habitDayKey(now);
    final notes = _notesController.text.trim();
    try {
      return await db.capturing(() async {
        final dao = db.habitDao;
        final id = await dao.createHabit(
          userId: userId,
          title: title,
          today: today,
          now: now,
          firstCommitment: _draft.commitment,
        );
        if (notes.isNotEmpty ||
            _draft.energyLevel != null ||
            _draft.estimateMinutes != null) {
          await dao.updateHabitDetails(
            habitId: id,
            userId: userId,
            title: title,
            notes: notes.isEmpty ? null : notes,
            energyLevel: _draft.energyLevel,
            timeEstimateMinutes: _draft.estimateMinutes,
            now: now,
          );
        }
        if (_draft.area != null) {
          await dao.setArea(
            habitId: id,
            userId: userId,
            areaTagId: _draft.area!.id,
          );
        }
        for (final label in labels) {
          await dao.assignLabel(habitId: id, userId: userId, tagId: label.id);
        }
        final anchor = _draft.anchor;
        if (anchor.kind != HabitAnchorKind.none) {
          await dao.setAnchor(
            habitId: id,
            userId: userId,
            today: today,
            now: now,
            kind: anchor.kind,
            partOfDay: anchor.partOfDay,
            clockTime: anchor.clockTime,
            anchorHabitId: anchor.anchorHabitId,
          );
        }
        return id;
      });
    } finally {
      _saving = false;
    }
  }

  Future<void> _submitDraftTitle() async {
    final id = await _saveDraft();
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
        if (didPop && _isDraft) _saveDraft();
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
      candidates: const [],
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
          onTap: () async {
            final picked = await _pickEstimate(context, estimate);
            if (picked != null) await _setEstimate(habit, picked.minutes);
          },
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
    await _dao.setCommitment(
      habitId: habit.id,
      userId: _userId,
      today: _today,
      now: _now,
      commitment: next,
    );
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
    await _dao.setAnchor(
      habitId: habit.id,
      userId: _userId,
      today: _today,
      now: _now,
      kind: next.kind,
      partOfDay: next.partOfDay,
      clockTime: next.clockTime,
      anchorHabitId: next.anchorHabitId,
    );
  }

  Future<void> _setArea(Habit? habit, Tag? tag) async {
    if (habit == null) {
      setState(() => _draft.area = tag);
      return;
    }
    await _dao.setArea(habitId: habit.id, userId: _userId, areaTagId: tag?.id);
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
      onAssign: (ref, tag) =>
          _dao.assignLabel(habitId: habit.id, userId: _userId, tagId: tag.id),
      onRemove: (ref, tag) =>
          _dao.unassignLabel(habitId: habit.id, userId: _userId, tagId: tag.id),
    );
  }

  Future<void> _setEnergy(Habit? habit, String? level) async {
    if (habit == null) {
      setState(() => _draft.energyLevel = level);
      return;
    }
    await _updateDetails(habit, energy: level);
  }

  Future<void> _setEstimate(Habit? habit, int? minutes) async {
    if (habit == null) {
      setState(() => _draft.estimateMinutes = minutes);
      return;
    }
    await _updateDetails(habit, estimate: minutes);
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
                    () => _dao.pause(
                      habitId: habit.id,
                      userId: _userId,
                      today: _today,
                      now: _now,
                      resumesOn: choice.resumesOn,
                    ),
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
                  () => _dao.resume(
                    habitId: habit.id,
                    userId: _userId,
                    today: _today,
                    now: _now,
                  ),
                  null,
                  '',
                ),
                child: const Text('Resume'),
              ),
            if (state != HabitState.archived)
              OutlinedButton(
                key: const Key('habit_archive'),
                onPressed: () => run(
                  () => _dao.archive(
                    habitId: habit.id,
                    userId: _userId,
                    today: _today,
                    now: _now,
                  ),
                  HabitFlash.archived,
                  'Its Check-ins are kept. Restore it any time.',
                ),
                child: const Text('Archive'),
              ),
            if (state == HabitState.archived)
              OutlinedButton(
                key: const Key('habit_restore'),
                onPressed: () => run(
                  () => _dao.restore(
                    habitId: habit.id,
                    userId: _userId,
                    today: _today,
                    now: _now,
                  ),
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

const Object _keep = Object();

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

/// An estimate chosen on the sheet; [minutes] null clears it.
class _EstimatePick {
  const _EstimatePick(this.minutes);
  final int? minutes;
}

Future<_EstimatePick?> _pickEstimate(BuildContext context, int? current) {
  return showModalBottomSheet<_EstimatePick>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in estimateLadderMinutes)
              ChoiceChip(
                key: Key('habit_estimate_$m'),
                label: Text('$m min'),
                selected: current == m,
                onSelected: (_) => Navigator.of(ctx).pop(_EstimatePick(m)),
              ),
            ActionChip(
              key: const Key('habit_estimate_clear'),
              label: const Text('No estimate'),
              onPressed: () => Navigator.of(ctx).pop(const _EstimatePick(null)),
            ),
          ],
        ),
      ),
    ),
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
