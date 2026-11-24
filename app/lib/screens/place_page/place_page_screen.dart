/// The place page: every Outcome with a Place, grouped by Place (issue #55).
///
/// This is where an Outcome hidden because the user is somewhere else can be
/// found. It is a list and nothing more: no map, no errands, no route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/place_page_provider.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_row.dart';

/// The list of every Outcome with a Place.
class PlacePageScreen extends ConsumerWidget {
  const PlacePageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(placePageGroupsProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AsyncList<PlacePageGroup>(
                asyncValue: groups,
                emptyIcon: Icons.place_outlined,
                emptyTitle: 'Nothing at a place',
                emptySubtitle:
                    'Outcomes you give a place to are listed here.',
                dataBuilder: (context, entries) => CustomScrollView(
                  slivers: [
                    for (final entry in entries) ...[
                      SliverToBoxAdapter(
                        child: _SectionHeader(name: entry.label),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final row = entry.rows[i];
                            return OutcomeRow(
                              key: Key('place_page_row_${row.todo.id}'),
                              title: row.todo.title,
                              energyLevel: row.todo.energyLevel,
                              timeEstimateMinutes: row.todo.timeEstimate,
                              dueDate: row.todo.dueDate,
                              secondary: PlaceMarker(isOnNext: row.isOnNext),
                              onTap: () =>
                                  context.push('/task/${row.todo.id}'),
                            );
                          },
                          childCount: entry.rows.length,
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The marker that says where a row stands: "On Next" or "Elsewhere".
///
/// The text carries the state, not the colour: the two markers differ in
/// their words and their shape.
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({super.key, required this.isOnNext});

  /// Whether the Outcome is on Next — the user is at its Place.
  final bool isOnNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key(isOnNext ? 'place_marker_on_next' : 'place_marker_elsewhere'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isOnNext ? Icons.check_circle_outline : Icons.place_outlined,
          size: 14,
          color: const Color(0xFF9CA3AF),
        ),
        const SizedBox(width: 4),
        Text(
          isOnNext ? 'On Next' : 'Elsewhere',
          style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF9CA3AF),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
