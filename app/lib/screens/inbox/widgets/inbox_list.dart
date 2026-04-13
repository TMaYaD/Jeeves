import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/inbox_provider.dart';
import 'todo_list_item.dart';

/// The scrollable inbox list with pull-to-refresh support.
class InboxList extends ConsumerWidget {
  const InboxList({super.key, required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(inboxItemsProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) => RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: items.isEmpty ? 1 : items.length,
          separatorBuilder: (_, _) =>
              items.isEmpty ? const SizedBox.shrink() : const Divider(height: 1),
          itemBuilder: (_, index) {
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.only(top: 120),
                child: Center(child: Text('No items yet — add something above')),
              );
            }
            return TodoListItem(todo: items[index]);
          },
        ),
      ),
    );
  }
}
