/// The screen a build shows when it cannot open the local data on the device.
///
/// It stands in for the app in two cases: the data was written by a newer
/// build of Jeeves, and the data could not be read at all. The words differ
/// — `store_too_new_copy.dart` and `store_unreadable_copy.dart` — and the
/// screen is the same, because the promise it makes is the same.
///
/// **It offers no action at all.** There is no button that
/// deletes the store, resets it or starts fresh: the data is intact, and
/// whether it belongs to a newer Jeeves or simply could not be read, the
/// only thing that can read it is a build that understands it. A control that
/// offered to throw the data away would be the one thing on this screen that
/// could destroy it.
///
/// The words are the copy file's.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/build_version_provider.dart';
import 'store_blocked_copy.dart';

class StoreBlockedScreen extends ConsumerWidget {
  const StoreBlockedScreen({super.key, required this.copy});

  /// The words this screen says, and why it is here.
  final StoreBlockedCopy copy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final buildVersion = ref.watch(buildVersionLabelProvider);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(copy.title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  Text(copy.explanation,
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Text(copy.advice, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  buildVersion.when(
                    data: (label) => Text(
                      '$storeBlockedRunningVersionLabel$label',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFF6B7280)),
                    ),
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
