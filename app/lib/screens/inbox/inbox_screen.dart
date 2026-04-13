import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/connectivity_provider.dart';
import '../../providers/inbox_provider.dart';
import '../../services/sync_service.dart';
import 'widgets/inbox_list.dart';
import 'widgets/offline_chip.dart';
import 'widgets/quick_add_bar.dart';

/// Root screen: the GTD inbox capture view.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(inboxItemsProvider);
    final count = asyncItems.asData?.value.length ?? 0;

    final isOnline = ref.watch(isOnlineProvider).asData?.value ?? true;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Inbox'),
            if (count > 0) ...[
              const SizedBox(width: 8),
              _CountBadge(count: count),
            ],
          ],
        ),
        actions: [
          if (!isOnline) const Padding(
            padding: EdgeInsets.only(right: 8),
            child: OfflineChip(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InboxList(
              onRefresh: ref.read(syncServiceProvider).sync,
            ),
          ),
          QuickAddBar(
            controller: _controller,
            onAdd: (title) =>
                ref.read(inboxNotifierProvider).addTodo(title),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
