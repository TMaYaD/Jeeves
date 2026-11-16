import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../models/plan_capacity.dart';
import '../../providers/clock_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/focus_session_planning_provider.dart';
import '../../providers/focus_session_planning_settings_provider.dart';
import '../../providers/nudge_clock_provider.dart';
import '../../providers/time_context_provider.dart';
import '../../widgets/meta_chip.dart';
import '../../widgets/outcome_row.dart';

/// Next Outcomes (everything in the Next list, whatever its time context).
final _addToPlanNextPoolProvider = StreamProvider.autoDispose<List<Todo>>(
    (ref) => ref.watch(databaseProvider).todoDao.watchNext());

/// Someday/Maybe and Waiting For Outcomes, offered only through search.
final _addToPlanOffNextPoolProvider = StreamProvider.autoDispose<List<Todo>>(
    (ref) => ref
        .watch(databaseProvider)
        .todoDao
        .watchOffUpNextPlanningCandidates());

/// "Add to Today's Plan": the deliberate way to put one more Outcome on the
/// open session's Plan (issue #700). The capacity note is advisory; adding is
/// never refused for it.
class AddToPlanScreen extends ConsumerStatefulWidget {
  const AddToPlanScreen({super.key});

  @override
  ConsumerState<AddToPlanScreen> createState() => _AddToPlanScreenState();
}

class _AddToPlanScreenState extends ConsumerState<AddToPlanScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _selectedId;
  bool _adding = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(Todo t) => t.title.toLowerCase().contains(_query);

  Future<void> _add(FocusSession session, String taskId) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await ref.read(databaseProvider).focusSessionDao.addOutcomeToPlan(
            sessionId: session.id,
            taskId: taskId,
            now: ref.read(clockProvider)(),
          );
      if (mounted) context.pop();
    } catch (_) {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't add that to today's plan.")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeSessionProvider).value;
    final plan = ref.watch(activeSessionTasksProvider).value ?? const <Todo>[];
    final planIds = plan.map((t) => t.id).toSet();
    final outsideTimeContext = ref.watch(outsideTimeContextOutcomeIdsProvider);
    final next = (ref.watch(_addToPlanNextPoolProvider).value ?? const <Todo>[])
        .where((t) =>
            !planIds.contains(t.id) &&
            t.doneAt == null &&
            !outsideTimeContext.contains(t.id));
    final searching = _query.isNotEmpty;
    final nextRows = next.where((t) => !searching || _matches(t)).toList();
    final offNext = !searching
        ? const <OffUpNextCandidate>[]
        : [
            for (final t in ref.watch(_addToPlanOffNextPoolProvider).value ??
                const <Todo>[])
              if (!planIds.contains(t.id) && t.doneAt == null && _matches(t))
                (
                  todo: t,
                  reason: t.intent == 'maybe'
                      ? OffUpNextReason.someday
                      : OffUpNextReason.waitingFor,
                ),
            for (final t in ref.watch(_addToPlanNextPoolProvider).value ??
                const <Todo>[])
              if (!planIds.contains(t.id) &&
                  t.doneAt == null &&
                  outsideTimeContext.contains(t.id) &&
                  _matches(t))
                (todo: t, reason: OffUpNextReason.outsideTimeContext),
          ];

    final defaultEstimate = ref.watch(
      focusSessionPlanningSettingsProvider
          .select((s) => s.defaultTimeEstimate),
    );
    Todo? selected;
    for (final t in [...nextRows, ...offNext.map((c) => c.todo)]) {
      if (t.id == _selectedId) selected = t;
    }

    String? warning;
    if (session != null && selected != null) {
      final timeLeft = planTimeLeftMinutes(
        sessionStartedAt: DateTime.parse(session.startedAt).toLocal(),
        availableMinutes: ref.watch(openSessionAvailableMinutesProvider),
        now: ref.watch(clockProvider)(),
      );
      final planMinutes = unfinishedPlanEstimateMinutes(plan, defaultEstimate);
      final candidateMinutes = selected.timeEstimate ?? defaultEstimate;
      if (planExceedsTimeLeft(
        unfinishedPlanMinutes: planMinutes,
        candidateEstimateMinutes: candidateMinutes,
        timeLeftMinutes: timeLeft,
      )) {
        warning = 'That would exceed the time left. Estimates total '
            '${formatMinutesLabel(planMinutes + candidateMinutes)}; '
            '${formatMinutesLabel(timeLeft)} remain. '
            'You may add it regardless.';
      }
    }

    Widget row(Todo t, {String? reasonLabel}) {
      final isSelected = t.id == _selectedId;
      return OutcomeRow(
        key: ValueKey('add_to_plan_row_${t.id}'),
        title: t.title,
        framed: true,
        borderColor:
            isSelected ? const Color(0xFF2667B7) : const Color(0xFFE5E7EB),
        leading: Icon(
          isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
          size: 20,
          color:
              isSelected ? const Color(0xFF2667B7) : const Color(0xFF9CA3AF),
        ),
        meta: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutcomeMetaLine(timeEstimateMinutes: t.timeEstimate),
            if (reasonLabel != null)
              Text(reasonLabel,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
          ],
        ),
        onTap: () => setState(() => _selectedId = t.id),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: TextButton(
          key: const Key('add_to_plan_cancel'),
          onPressed: () => context.pop(),
          child: const Text('Cancel'),
        ),
        leadingWidth: 88,
        title: const Text("Add to Today's Plan"),
      ),
      body: session == null
          ? const Center(child: Text('No session is open.'))
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    'Another for the day, sir? Choose an Outcome. It will be '
                    'marked as added during the day.',
                    style: TextStyle(fontSize: 14, color: Color(0xFF4B5563)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    key: const Key('add_to_plan_search'),
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      hintText: 'Search tasks',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (nextRows.isEmpty && offNext.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('Nothing else to add.'),
                        ),
                      ...nextRows.map(row),
                      if (offNext.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.only(top: 16, bottom: 8),
                          child: Text(
                            'Not in Up Next',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        ...offNext
                            .map((c) => row(c.todo, reasonLabel: c.reason.label)),
                      ],
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (warning != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              warning,
                              key: const Key('add_to_plan_warning'),
                              style: const TextStyle(
                                color: Color(0xFFB91C1C),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        FilledButton(
                          key: const Key('add_to_plan_confirm'),
                          onPressed: selected == null || _adding
                              ? null
                              : () => _add(session, selected!.id),
                          child: Text(warning == null ? 'Add' : 'Add anyway'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
