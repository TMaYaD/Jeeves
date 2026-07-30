import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/database_provider.dart';
import '../../providers/inbox_provider.dart';
import '../../widgets/active_filter_bar.dart';
import 'widgets/inbox_list.dart';
import 'widgets/quick_add_bar.dart';

/// Root screen: the GTD inbox capture view.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  final _controller = TextEditingController();

  Future<void> _addCapture(String title) async {
    try {
      await ref.read(inboxNotifierProvider).addCapture(title);
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Active tag filter strip (shown only when filter is active).
            // The title, drawer, and unprocessed-count badge live in the shared
            // AppShell title bar (ADR-0021).
            const ActiveFilterBar(),
            // Quick add bar (pill-shaped input)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: QuickAddBar(
                controller: _controller,
                onAdd: _addCapture,
              ),
            ),
            // Inbox list
            Expanded(
              child: InboxList(
                onRefresh: () async {
                  // The spine pulls on its own signal — pull-to-refresh is
                  // purely a UX affordance. Awaiting the store's open ensures
                  // the list is reading a database that exists before control
                  // returns to the gesture; a failure to open is surfaced via a
                  // snackbar so the gesture resolves cleanly.
                  try {
                    await ref.read(domainStoreProvider.future);
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
