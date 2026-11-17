/// The screen a build shows when the local data on the device was written by a
/// newer build of Jeeves.
///
/// **It offers no action at all.** There is no button that
/// deletes the store, resets it or starts fresh: the data is intact and
/// belongs to a newer Jeeves, and the only thing that can read it is that
/// newer Jeeves. A control that offered to throw the data away would be the
/// one thing on this screen that could destroy it.
///
/// The words are `store_too_new_copy.dart`'s.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/build_version_provider.dart';
import 'store_too_new_copy.dart';

class StoreTooNewScreen extends ConsumerWidget {
  const StoreTooNewScreen({super.key});

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
                  Text(storeTooNewTitle, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  Text(storeTooNewExplanation,
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  Text(storeTooNewAdvice, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  buildVersion.when(
                    data: (label) => Text(
                      '$storeTooNewRunningVersionLabel$label',
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
