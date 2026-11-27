/// The Next list's empty state (issue #1076).
///
/// Two things can leave Next empty: there is nothing on it, or everything on
/// it is waiting for its time or its place. The second is not emptiness — the
/// Outcomes are there, they are just not now — so it gets its own state: one
/// calm line from a pool, and a way out to the time page and the place page,
/// which list every Outcome that has a time or a place, hidden or not.
///
/// The state says no count of hidden Outcomes and offers no way to show them
/// here: Next shows what can be done now, and the pages it links to are where
/// the waiting ones are.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/gtd_lists_provider.dart';
import '../../widgets/state_surfaces.dart';

/// Jeeves's lines for a Next list that is empty only because everything on it
/// is waiting — a title over a subtitle, drawn once.
const nextAllHiddenPool = <(String, String)>[
  (
    'Next is quiet, sir, not empty.',
    'Everything on it is waiting for its hour or its place, and will come '
        'back on its own.',
  ),
  (
    'All of it is waiting, sir.',
    'Each Outcome on Next has a time or a place, and neither is now. '
        'Nothing has been lost.',
  ),
  (
    'Nothing to be done just here and now, sir.',
    'Your Outcomes are safe. Each is waiting for its time or its place.',
  ),
];

final _random = Random();

/// The empty state of the Next list.
///
/// Ordinary emptiness and all-hidden emptiness read the same list, so the
/// two are told apart by [nextAllHiddenProvider].
class NextEmptyState extends ConsumerStatefulWidget {
  const NextEmptyState({super.key});

  @override
  ConsumerState<NextEmptyState> createState() => _NextEmptyStateState();
}

class _NextEmptyStateState extends ConsumerState<NextEmptyState> {
  /// The line, picked once: a line that changed its wording on every rebuild
  /// would read as if Jeeves kept changing his mind.
  late final (String, String) _line =
      nextAllHiddenPool[_random.nextInt(nextAllHiddenPool.length)];

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(nextAllHiddenProvider)) {
      return const EmptySurface(
        icon: Icons.task_alt,
        title: 'Nothing on Next',
        subtitle: 'Clarify an inbox item to add one.',
      );
    }
    return _AllHiddenSurface(
      title: _line.$1,
      subtitle: _line.$2,
      cta: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            key: const Key('next_all_hidden_time'),
            onPressed: () => context.go('/time'),
            icon: const Icon(Icons.schedule_outlined),
            label: const Text('Time'),
          ),
          TextButton.icon(
            key: const Key('next_all_hidden_places'),
            onPressed: () => context.go('/places'),
            icon: const Icon(Icons.place_outlined),
            label: const Text('Places'),
          ),
        ],
      ),
    );
  }
}

/// The surface for a Next list that is empty only because everything on it is
/// waiting.
///
/// It carries Jeeves's own words, so it wears the Jeeves-speak treatment
/// (docs/DESIGN.md § Voice): a bold header line over a lighter subtitle, set
/// apart from ordinary copy. [EmptySurface]'s plain grey styles are for
/// functional copy, so the all-hidden state styles the pair itself rather than
/// borrowing those. The ordinary empty state is untouched.
class _AllHiddenSurface extends StatelessWidget {
  const _AllHiddenSurface({
    required this.title,
    required this.subtitle,
    required this.cta,
  });

  /// Jeeves-speak ink: the header's colour.
  static const _ink = Color(0xFF1A1A2E);

  /// The subtitle's colour: lighter than the header, the same muted tone the
  /// onboarding card uses for its second line.
  static const _inkMuted = Color(0xFF6B7280);

  /// The glyph's tone, as [EmptySurface]'s icon.
  static const _iconTone = Color(0xFFD1D5DB);

  final String title;
  final String subtitle;
  final Widget cta;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('next_all_hidden'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bedtime_outlined, size: 48, color: _iconTone),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: _ink,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: _inkMuted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            cta,
          ],
        ),
      ),
    );
  }
}
