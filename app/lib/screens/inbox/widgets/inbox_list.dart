import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/inbox_provider.dart';
import 'todo_list_item.dart';

class _TightBouncingScrollPhysics extends BouncingScrollPhysics {
  const _TightBouncingScrollPhysics({super.parent});

  @override
  _TightBouncingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TightBouncingScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double frictionFactor(double overscrollFraction) {
    // Default is 0.52 * pow(1 - fraction, 2) — allows large overscroll.
    // This cuts drag to ~15% and drops off sharply, limiting overscroll
    // to roughly 25% of viewport before it feels stuck.
    return 0.52 * math.pow(0.5 - overscrollFraction, 4);
  }

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 1,
        stiffness: 200,
        damping: 30,
      );
}

/// The scrollable inbox list with pull-to-refresh support.
class InboxList extends ConsumerWidget {
  const InboxList({super.key, required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(inboxItemsProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) {
        debugPrint('InboxList error: $err\n$stack');
        return const Center(
          child: Text('Could not load inbox. Pull to refresh and try again.'),
        );
      },
      data: (items) => RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.builder(
          physics: const _TightBouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.only(top: 8),
          itemCount: items.isEmpty ? 1 : items.length,
          itemBuilder: (_, index) {
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(
                  child: Text(
                    'No items yet — add something above',
                    style: TextStyle(color: Color(0xFF9CA3AF)),
                  ),
                ),
              );
            }
            return TodoListItem(
              todo: items[index],
              onTap: () => context.push('/task/${items[index].id}'),
            );
          },
        ),
      ),
    );
  }
}
