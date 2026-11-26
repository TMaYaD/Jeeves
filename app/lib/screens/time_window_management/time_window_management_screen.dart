import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/time_window_hours.dart';
import '../../providers/database_provider.dart';
import '../../providers/time_window_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../../widgets/time_window_editor_sheet.dart';

/// What Jeeves says when the user has no time windows yet. One of the pool is
/// picked at random, so the app does not repeat itself.
const timeWindowEmptyStatePool = <String>[
  'No time windows yet, sir. Make one when a place keeps its own hours.',
  'Nothing on the clock but the day itself, sir.',
  'No named windows yet. A shop with hours of its own would make one.',
];

/// The user's named time windows: each with its hours and the number of
/// current Actions of active Outcomes that use it. Tapping a row opens the
/// editor; the title bar's New action makes one.
class TimeWindowManagementScreen extends ConsumerWidget {
  const TimeWindowManagementScreen({super.key});

  /// Where Settings opens the list.
  static const routePath = '/manage/time-windows';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.watch(timeWindowsWithUseCountProvider);
    return Scaffold(
      appBar: AppTitleBar(
        title: 'Time windows',
        pageActions: [
          AppTitleBarAction(
            key: const Key('time_window_new'),
            icon: Icons.add,
            label: 'New',
            onPressed: () => showTimeWindowEditorSheet(context),
          ),
        ],
        pinnedAction: captureAction(context),
      ),
      backgroundColor: Colors.white,
      body: windows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) =>
            const Center(child: Text('Could not load the time windows')),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Text(
                timeWindowEmptyStatePool[
                    DateTime.now().millisecondsSinceEpoch % timeWindowEmptyStatePool.length],
                key: const Key('time_window_management_empty'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF9CA3AF)),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final row = rows[i];
              final hours = TimeWindowHours.tryParse(row.window.hours);
              return ListTile(
                key: Key('time_window_row_${row.window.id}'),
                title: Text(
                  row.window.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                ),
                subtitle: Text(
                  hours?.describe() ?? 'Unreadable hours',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF9CA3AF)),
                ),
                trailing: Text(
                  '${row.useCount}',
                  style: const TextStyle(color: Color(0xFF9CA3AF)),
                ),
                onTap: () async {
                  final placeUseCount = await ref
                      .read(databaseProvider)
                      .timeWindowDao
                      .placeUseCount(row.window.id);
                  if (!context.mounted) return;
                  await showTimeWindowEditorSheet(
                    context,
                    window: row.window,
                    useCount: row.useCount,
                    placeUseCount: placeUseCount,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
