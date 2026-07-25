import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/inbox_provider.dart';
import '../../../providers/onboarding_provider.dart';
import '../../../database/gtd_database.dart';
import '../../../widgets/async_list.dart';
import '../../../widgets/onboarding_card.dart';
import 'capture_list_item.dart';

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

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: AsyncList<Capture>(
        asyncValue: asyncItems,
        // Dead fallback — the emptyBuilder below always supplies the surface —
        // but kept in Jeeves's voice for hygiene.
        emptyTitle: inboxEmptyStateLines.first,
        emptyBuilder: (_) => const _InboxEmptyState(),
        dataBuilder: (context, items) => ListView.builder(
          physics: const _TightBouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.only(top: 8),
          itemCount: items.length,
          itemBuilder: (_, index) => CaptureListItem(
            capture: items[index],
            onTap: () => context.push('/inbox/${items[index].id}/clarify'),
          ),
        ),
      ),
    );
  }
}

/// Jeeves-speak lines for the empty Inbox once onboarding is dismissed — first
/// person, addressed to "sir", framing the input as how you tell Jeeves rather
/// than as UI instruction (see DESIGN.md § Voice). One is drawn at random per
/// display, mirroring the nudge-banner pool pattern
/// (`lib/widgets/nudge_banner.dart`).
const inboxEmptyStateLines = <String>[
  "All quiet, sir. Should a thought arise, you've only to tell me.",
  "A clear slate, sir. The moment anything surfaces, do let me know.",
  "Nothing wants attention, sir. When something comes to mind, only say the word.",
];

final _emptyStateRandom = math.Random();

/// Inbox's empty surface: shows the OnboardingCard CTA until the user has
/// seen it, then a Jeeves-speak reassurance drawn at random.
///
/// Wraps itself in a single-child [ListView] so the enclosing
/// [RefreshIndicator] still fires when there's nothing to scroll — the
/// inbox owns its physics (tight bouncing) rather than delegating to
/// [AsyncList].
class _InboxEmptyState extends StatefulWidget {
  const _InboxEmptyState();

  @override
  State<_InboxEmptyState> createState() => _InboxEmptyStateState();
}

class _InboxEmptyStateState extends State<_InboxEmptyState> {
  // Drawn once per display so the line stays stable across rebuilds.
  late final String _line =
      inboxEmptyStateLines[_emptyStateRandom.nextInt(inboxEmptyStateLines.length)];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: onboardingSeenNotifier,
      builder: (context, seen, _) {
        final child = seen
            ? Padding(
                padding: const EdgeInsets.fromLTRB(32, 120, 32, 0),
                child: Center(
                  child: Text(
                    _line,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF9CA3AF)),
                  ),
                ),
              )
            : const Padding(
                padding: EdgeInsets.only(top: 120),
                child: OnboardingCard(),
              );
        return ListView(
          physics: const _TightBouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          children: [child],
        );
      },
    );
  }
}
