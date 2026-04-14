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
    final isOnline = ref.watch(isOnlineProvider).asData?.value ?? true;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: title + offline chip
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Text(
                      'Inbox',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
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
                onAdd: (title) =>
                    ref.read(inboxNotifierProvider).addTodo(title),
              ),
            ),
            // Inbox list
            Expanded(
              child: InboxList(
                onRefresh: ref.read(syncServiceProvider).sync,
              ),
            ),
          ],
        ),
      ),
    );
  }

}
