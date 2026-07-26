/// Standalone clarify screen for a single Inbox Capture.
///
/// Opened when the user taps an inbox row outside of a planning session. It is
/// a **host**, not a second implementation: the body is [ClarifyCard], the
/// same widget every ceremony clarify surface renders, so the fields, the
/// draft assembly, the live-subject reconciliation and the routing writes
/// cannot drift from those surfaces. What this screen owns is the chrome the
/// card deliberately has none of — the app bar, the platform-back guard and
/// Skip.
///
/// Two things distinguish it from the ceremony surfaces, both expressed as
/// arguments rather than as different code:
///
/// - [ClarifyTagSection.draftInputOnly] — no tag pickers, and the Capture's
///   hints read once as draft input for the new Outcome.
/// - No retention store. This screen's only two exits, Skip and back, are both
///   deliberate leaves; there is no in-flow navigation to protect, so an
///   in-progress draft is not carried anywhere.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../../widgets/clarify_card.dart';
import '../../widgets/clarify_shared_widgets.dart';

class InboxClarifyScreen extends ConsumerStatefulWidget {
  const InboxClarifyScreen({super.key, required this.captureId});

  final String captureId;

  @override
  ConsumerState<InboxClarifyScreen> createState() => _InboxClarifyScreenState();
}

class _InboxClarifyScreenState extends ConsumerState<InboxClarifyScreen> {
  /// Mirrors [ClarifyCard]'s in-flight state, so every affordance that leaves
  /// this screen — Skip, the app-bar back button, platform back, the pinned
  /// capture action — shuts alongside the action bar's own buttons.
  ///
  /// Popping mid-write is not merely cosmetic: the routing verdict lands
  /// against a screen the user has already left, so the tap that started it
  /// gives no feedback and a failure has nowhere to report.
  bool _routing = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Platform back is the one escape no widget owns, so it needs the guard
      // here rather than an `enabled:` flag.
      canPop: !_routing,
      child: Scaffold(
        backgroundColor: Colors.white,
        // The back arrow is gated while a route transition is in flight via
        // leadingEnabled — platform back has its own guard in the PopScope.
        appBar: AppTitleBar(
          title: 'Clarify',
          leadingEnabled: !_routing,
          // Suppress capture while a route is in flight, alongside the back
          // arrow and Skip. Belt-and-braces: the sheet mounts on the root
          // navigator so the pop below can no longer strand a user on top of
          // it, but a Capture opened mid-route is still an interaction this
          // guarded window should not offer.
          pinnedAction: _routing ? null : captureAction(context),
        ),
        body: ClarifyCard.forCapture(
          captureId: widget.captureId,
          // No pickers here: the hints are consumed once as draft input for
          // the Outcome, and this screen renders no chips for a live stream to
          // keep in step.
          tagSection: ClarifyTagSection.draftInputOnly,
          // Skip is a nav escape hatch, not a verdict — it leaves
          // `clarified_at` NULL and the Capture in the Inbox — so it stays
          // outside the routing bar, and so it does not inherit the bar's
          // in-flight disabling for free (see [_routing]).
          footer: ClarifyDestinationButton(
            label: 'Skip',
            icon: Icons.next_plan_outlined,
            color: const Color(0xFF6B7280),
            enabled: !_routing,
            onTap: () => context.pop(),
          ),
          // This screen is its own route, so the app-bar back arrow is the
          // only other exit — and it is not an affordance the missing state
          // points at. Name the destination instead: pop lands on the Inbox.
          missingCta: TextButton(
            onPressed: () => context.pop(),
            child: const Text('Back to Inbox'),
          ),
          onProcessingChanged: (busy) {
            if (mounted) setState(() => _routing = busy);
          },
          // The verdict is committed and nothing here writes the Capture
          // (ADR-0023), so leaving is the whole of the post-verdict work.
          // Both hooks are wired: the 1-1 routing verdict and the n-m
          // completing one.
          onAfterRoute: (_) async {
            if (mounted) context.pop();
          },
          onCaptureCompleted: () async {
            if (mounted) context.pop();
          },
        ),
      ),
    );
  }
}
