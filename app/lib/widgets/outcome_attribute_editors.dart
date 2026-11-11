/// Attribute editors shared by the Task Detail screen and the Daily Planning
/// Outcome peek: time estimate, energy and context-tag sheets, and the due-date
/// picker. A behaviour-preserving move out of `task_detail_screen.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/task_detail_provider.dart';
import 'clarify_shared_widgets.dart';
import 'context_tag_picker.dart';
import 'meta_chip.dart';

void showOutcomeContextTagEditor(BuildContext context, String todoId) {
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
                  ref.watch(taskTagsProvider(todoId)).asData?.value ??
                      const <Tag>[];
              final contextTags =
                  tags.where((t) => t.type == 'context').toList();
              return ContextTagPickerWidget(
                assignedTags: contextTags,
                onAssign: (tag) =>
                    ref
                        .read(taskDetailNotifierProvider(todoId))
                        .assignContextTag(tag.id)
                        .ignore(),
                onRemove: (tag) =>
                    ref
                        .read(taskDetailNotifierProvider(todoId))
                        .removeContextTag(tag.id)
                        .ignore(),
              );
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> showOutcomeTimeEstimateSheet(
    BuildContext context, TaskDetailNotifier notifier, int? current) async {
  // The shared ladder plus a `null` "None" row — the same options and the
  // same labels the clarify surfaces and the planned-action sheet offer, so
  // an estimate reads identically wherever it is set or shown.
  final times = <int?>[...kEstimateOptionsMinutes, null];
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
                  title: Text(val == null ? 'None' : formatMinutesLabel(val), style: const TextStyle(color: Color(0xFF374151))),
                  trailing: val == current ? const Icon(Icons.check, color: Color(0xFF2563EB)) : null,
                  onTap: () {
                    if (val == null) {
                      notifier.clearTimeEstimate();
                    } else {
                      notifier.setTimeEstimate(val);
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

Future<void> showOutcomeEnergyLevelSheet(
    BuildContext context, TaskDetailNotifier notifier, String? current) async {
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
                  notifier.clearEnergyLevel();
                } else {
                  notifier.setEnergyLevel(s.first!);
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


/// Opens the due-date picker. Returns the picked date, or null when dismissed
/// (which means "no change", not "clear the date").
Future<DateTime?> pickOutcomeDueDate(BuildContext context, DateTime? current) {
  return showDatePicker(
    context: context,
    initialDate: current?.toLocal() ?? DateTime.now(),
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
    builder: (ctx, child) => Theme(
      data: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(primary: Color(0xFF2563EB)),
      ),
      child: child!,
    ),
  );
}
