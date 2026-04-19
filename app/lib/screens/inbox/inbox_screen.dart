import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/connectivity_provider.dart';
import '../../providers/inbox_provider.dart';
import '../../providers/powersync_provider.dart';
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

  Future<void> _addTodo(String title) async {
    try {
      await ref.read(inboxNotifierProvider).addTodo(title);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add item')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider).asData?.value ?? true;
    final inboxCount =
        ref.watch(inboxItemsProvider).asData?.value.length ?? 0;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: title + count badge + offline chip
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 20, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Builder(
                          builder: (ctx) => IconButton(
                            icon: const Icon(Icons.menu),
                            onPressed: () {
                              ctx.findRootAncestorStateOfType<ScaffoldState>()?.openDrawer();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Inbox',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        if (inboxCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE5E7EB),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text('$inboxCount'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!isOnline) const OfflineChip(),
                ],
              ),
            ),
            // Quick add bar (pill-shaped input)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: QuickAddBar(
                controller: _controller,
                onAdd: _addTodo,
              ),
            ),
            // Inbox list
            Expanded(
              child: InboxList(
                onRefresh: () async {
                  // PowerSync syncs continuously while connected — pull-to-
                  // refresh is purely a UX affordance.  Awaiting the
                  // provider's future ensures the DB has been opened at
                  // least once before we return control to the gesture.
                  // Failures (e.g. PowerSync init error) are surfaced via a
                  // snackbar so the gesture resolves cleanly.
                  try {
                    await ref.read(powerSyncInstanceProvider.future);
                  } catch (_) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Unable to refresh')),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

}
