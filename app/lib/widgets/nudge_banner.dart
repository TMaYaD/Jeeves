/// Single in-app Banner surface for every Ritual's Nudge. Consumes the
/// **Nudge queue** (see `CONTEXT.md`'s **Banner** and **Nudge queue**
/// entries) — renders the highest-priority Ritual whose Nudge is currently
/// visible and whose banner-enabled setting is `true`. Tapping opens the
/// Ceremony; a horizontal swipe maps to a Nudge **dismiss** (current firing).
/// No Banner carries a ✕.
///
/// **Inbox too full** is not in the queue: it sits ahead of it
/// ([nudgeSurfaceHeadProvider]), is untinted, and cannot be swiped away.
///
/// Replaces the three bespoke per-Ritual banner widgets with one
/// queue-driven widget parametrised by a per-Ritual chrome matrix.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/ritual.dart';
import '../providers/focus_session_planning_settings_provider.dart';
import '../providers/nudge_provider.dart';
import '../providers/nudge_triggers.dart' show unfinishedReviewTriggerProvider;
import '../providers/periodic_review_settings_provider.dart'
    show periodicReviewBannerEnabledProvider;
import '../providers/database_provider.dart';
import '../providers/shutdown_settings_provider.dart';
import '../providers/system_trust_provider.dart'
    show
        inboxTooFullProvider,
        kInboxTooFullCaptureLimit,
        unprocessedCaptureCountProvider,
        weeklyReviewDaysLateProvider;
import '../screens/inbox/inbox_clarify_screen.dart'
    show inboxClarifySequenceLocation;

/// True iff the in-app Banner for [ritual] is enabled in user settings.
/// Each Ritual has its own enabled flag because the user might want to
/// silence one Ritual's in-app nag without silencing the rest.
final nudgeBannerEnabledProvider = Provider.family<bool, RitualId>((ref, ritual) {
  return switch (ritual) {
    RitualId.dailyPlanning =>
      ref.watch(focusSessionPlanningSettingsProvider).bannerEnabled,
    RitualId.eveningShutdown => ref.watch(shutdownSettingsProvider).bannerEnabled,
    RitualId.weeklyReview => ref.watch(periodicReviewBannerEnabledProvider),
  };
});

/// The Ritual whose Banner should currently render — the head of the
/// Nudge queue whose per-surface banner is enabled. Walks down the queue
/// rather than returning null when the head's banner is disabled, so a
/// silenced higher-priority Ritual does not hide a still-visible lower one.
final bannerVisibleRitualProvider = Provider<RitualId?>((ref) {
  final queue = ref.watch(nudgeQueueProvider);
  for (final r in queue) {
    if (ref.watch(nudgeBannerEnabledProvider(r))) return r;
  }
  return null;
});

/// What occupies the nudge slot on the Banner and the Now screen: Inbox too
/// full ahead of the Nudge queue, otherwise the first Banner-enabled member of
/// the queue. Inbox too full is not a Ritual, so it has no Nudge state, no
/// dismiss and no Notification.
sealed class NudgeSurfaceHead {
  const NudgeSurfaceHead();
}

class InboxTooFullHead extends NudgeSurfaceHead {
  const InboxTooFullHead();
  @override
  bool operator ==(Object other) => other is InboxTooFullHead;
  @override
  int get hashCode => 1;
}

class RitualHead extends NudgeSurfaceHead {
  const RitualHead(this.ritual);
  final RitualId ritual;
  @override
  bool operator ==(Object other) => other is RitualHead && other.ritual == ritual;
  @override
  int get hashCode => ritual.hashCode;
}

final nudgeSurfaceHeadProvider = Provider<NudgeSurfaceHead?>((ref) {
  if (ref.watch(inboxTooFullProvider)) return const InboxTooFullHead();
  final ritual = ref.watch(bannerVisibleRitualProvider);
  return ritual == null ? null : RitualHead(ritual);
});

/// What a nudge says and where it leads, shared by the Banner and the Now
/// screen's empty state so the two cannot drift.
class NudgeSurfaceContent {
  const NudgeSurfaceContent({
    required this.title,
    required this.sub,
    required this.cta,
    required this.accent,
    required this.ink,
    required this.inkMuted,
    required this.icon,
    required this.open,
  });
  final String title;
  final String sub;
  final String cta;
  final Color accent;
  final Color ink;
  final Color inkMuted;
  final IconData icon;

  /// Opens the Ceremony, or for Inbox too full the oldest Capture.
  final Future<void> Function(BuildContext context) open;
}

NudgeSurfaceContent nudgeSurfaceContent(WidgetRef ref, NudgeSurfaceHead head) {
  switch (head) {
    case InboxTooFullHead():
      final pair = _inboxTooFullPair(
        count: ref.watch(unprocessedCaptureCountProvider),
        seed: _dailySeed(DateTime.now()),
      );
      final skin = _inboxTooFullSkin;
      return NudgeSurfaceContent(
        title: pair.title,
        sub: pair.sub,
        cta: pair.cta,
        accent: skin.accent,
        ink: skin.ink,
        inkMuted: skin.inkMuted,
        icon: skin.icon,
        open: (context) async {
          final id = await ref
              .read(databaseProvider)
              .captureDao
              .oldestInboxCaptureId();
          if (!context.mounted) return;
          context.push(id == null ? '/inbox' : inboxClarifySequenceLocation(id));
        },
      );
    case RitualHead(:final ritual):
      final skin = _skins[ritual]!;
      final _Quip quip;
      if (ritual == RitualId.weeklyReview) {
        quip = _weeklyReviewQuip(
          now: DateTime.now(),
          unfinished: ref.watch(unfinishedReviewTriggerProvider).isFiring,
          daysLate: ref.watch(weeklyReviewDaysLateProvider),
        );
      } else {
        quip = skin.quipForToday();
      }
      return NudgeSurfaceContent(
        title: quip.title,
        sub: quip.sub,
        cta: quip.cta,
        accent: skin.accent,
        ink: skin.ink,
        inkMuted: skin.inkMuted,
        icon: skin.icon,
        open: (context) async => context.go(skin.route),
      );
  }
}

class NudgeBanner extends ConsumerWidget {
  const NudgeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final head = ref.watch(nudgeSurfaceHeadProvider);
    if (head == null) return const SizedBox.shrink();
    final content = nudgeSurfaceContent(ref, head);

    switch (head) {
      case InboxTooFullHead():
        return _BannerContent(
          key: const Key('inbox_too_full_banner_visible'),
          skin: _inboxTooFullSkin,
          quip: _Quip(content.title, content.sub, content.cta),
          onTap: () => content.open(context),
          // No swipe, no key, no semantics action: it clears only when the
          // Inbox is at 50 or fewer.
          onDismiss: null,
        );
      case RitualHead(:final ritual):
        return _BannerContent(
          key: Key('${ritual.keyPrefix}_banner_visible'),
          skin: _skins[ritual]!,
          quip: _Quip(content.title, content.sub, content.cta),
          onTap: () => content.open(context),
          onDismiss: () => ref.read(nudgeActionsProvider).dismiss(ritual),
        );
    }
  }
}

/// The Now screen's Today's Tasks empty state when [head] holds it: glyph, the
/// Jeeves pair and one full-width button in the nudge's accent. It has no
/// dismiss gesture.
class NudgeEmptyState extends ConsumerWidget {
  const NudgeEmptyState({super.key, required this.head});
  final NudgeSurfaceHead head;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = nudgeSurfaceContent(ref, head);
    return Column(
      key: const Key('nudge_empty_state'),
      children: [
        Icon(content.icon, size: 28, color: content.accent),
        const SizedBox(height: 12),
        Text(
          content.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: content.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          content.sub,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: content.inkMuted),
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('nudge_empty_state_button'),
          onPressed: () => content.open(context),
          style: FilledButton.styleFrom(
            backgroundColor: content.accent,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
          ),
          child: Text(
            content.cta,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Per-Ritual skin matrix
// ---------------------------------------------------------------------------

int _dailySeed(DateTime now) => now.year * 366 + now.month * 31 + now.day;

class _Quip {
  const _Quip(this.title, this.sub, this.cta);
  final String title;
  final String sub;
  final String cta;
}

class _Skin {
  const _Skin({
    required this.quips,
    required this.quipSeedOffset,
    required this.route,
    required this.bg,
    required this.accent,
    required this.ink,
    required this.inkMuted,
    required this.borderTint,
    required this.icon,
    required this.pulseDuration,
    required this.pulseFromScale,
    required this.pulseToScale,
    this.pulses = true,
  });

  final List<_Quip> quips;
  final int quipSeedOffset;
  final String route;
  final Color bg;
  final Color accent;
  final Color ink;
  final Color inkMuted;
  final int borderTint;
  final IconData icon;
  final Duration pulseDuration;
  final double pulseFromScale;
  final double pulseToScale;
  final bool pulses;

  _Quip quipForToday() =>
      quips[(_dailySeed(DateTime.now()) + quipSeedOffset) % quips.length];
}

final _skins = <RitualId, _Skin>{
  RitualId.dailyPlanning: const _Skin(
    quips: [
      _Quip('Shall we, sir?',
          'One prefers the day with a touch of forethought.',
          'Very good  →'),
      _Quip('A moment to plan, sir?',
          'The day has a way of escaping unsupervised.',
          'At once  →'),
      _Quip('If I may, sir…',
          'The day is not, regrettably, going to plan itself.',
          'Indeed  →'),
      _Quip('Might I suggest, sir?',
          'One finds the day more obliging when given instructions.',
          'Quite  →'),
      _Quip('Pardon me, sir.',
          'I have taken the liberty of reserving a moment for planning.',
          'Very good  →'),
      _Quip('Sir?',
          'A trifling five minutes before the day absconds with you.',
          'At once  →'),
      _Quip('Ahem, sir.', 'The day awaits your instructions.',
          'Indeed  →'),
    ],
    quipSeedOffset: 0,
    route: '/focus-session-planning',
    bg: Color(0xFFFEF3C7), // amber-100
    accent: Color(0xFFD97706), // amber-600
    ink: Color(0xFF78350F), // amber-900
    inkMuted: Color(0xFF92400E), // amber-800
    borderTint: 0x22D97706,
    icon: Icons.wb_sunny,
    pulseDuration: Duration(milliseconds: 1400),
    pulseFromScale: 0.92,
    pulseToScale: 1.08,
  ),
  RitualId.eveningShutdown: const _Skin(
    quips: [
      _Quip('A moment, sir?',
          'The day’s accounts require your attention before we close.',
          'Very good  →'),
      _Quip('If I may, sir…',
          'One prefers the evening with a touch of reflection.',
          'At once  →'),
      _Quip('Shall we close out, sir?',
          'Tomorrow is better served by a tidy ledger today.',
          'Indeed  →'),
      _Quip('Sir, the hour is nigh.',
          'A brief review before the curtain falls, perhaps?',
          'Quite  →'),
      _Quip('Pardon the intrusion, sir.',
          'One has taken the liberty of preparing the day’s summary.',
          'Very good  →'),
    ],
    quipSeedOffset: 3,
    route: '/shutdown',
    bg: Color(0xFFEEF2FF), // indigo-50
    accent: Color(0xFF4F46E5), // indigo-600
    ink: Color(0xFF1E1B4B), // indigo-950
    inkMuted: Color(0xFF3730A3), // indigo-800
    borderTint: 0x224F46E5,
    icon: Icons.nightlight_round,
    pulseDuration: Duration(milliseconds: 2000),
    pulseFromScale: 0.90,
    pulseToScale: 1.08,
  ),
  RitualId.weeklyReview: const _Skin(
    // The Weekly Review's lines are built by [_weeklyReviewQuip].
    quips: [],
    quipSeedOffset: 0,
    route: '/periodic-review',
    bg: Color(0xFFECFDF5), // emerald-50
    accent: Color(0xFF059669), // emerald-600
    ink: Color(0xFF065F46), // emerald-900
    inkMuted: Color(0xFF047857), // emerald-800
    borderTint: 0x22059669,
    icon: Icons.refresh_rounded,
    pulseDuration: Duration(milliseconds: 1400),
    pulseFromScale: 0.92,
    pulseToScale: 1.08,
  ),
};

/// Inbox too full is untinted: ink on white, no pulse, a filled-ink button.
const _inboxTooFullSkin = _Skin(
  quips: [],
  quipSeedOffset: 0,
  route: '/inbox',
  bg: Colors.white,
  accent: Color(0xFF1A1A2E), // ink
  ink: Color(0xFF1A1A2E),
  inkMuted: Color(0xFF6B7280),
  borderTint: 0x1F000000,
  icon: Icons.inbox_outlined,
  pulseDuration: Duration(milliseconds: 1400),
  pulseFromScale: 1,
  pulseToScale: 1,
  pulses: false,
);

/// Inbox too full line pairs. `%N` stands for the Capture count, `%L` for the
/// limit. Every pair must state both.
// TODO(copy): the real pool (Jeeves voice, every pair giving the count and the
// 50) comes from the board owner. This single neutral pair is a placeholder
// and must not merge.
const kInboxTooFullLinePairs = <(String, String)>[
  ('The Inbox holds %N Captures, sir.', 'The limit is %L.'),
];

/// The Bertie button, from the shipped pool.
const _inboxTooFullButton = 'At once  →';

_Quip _inboxTooFullPair({required int count, required int seed}) {
  final pair = kInboxTooFullLinePairs[seed % kInboxTooFullLinePairs.length];
  String fill(String line) => line
      .replaceAll('%N', '$count')
      .replaceAll('%L', '$kInboxTooFullCaptureLimit');
  return _Quip(fill(pair.$1), fill(pair.$2), _inboxTooFullButton);
}

// ---------------------------------------------------------------------------
// Weekly Review copy
// ---------------------------------------------------------------------------

/// One row of the Weekly Review pool: lines and buttons drawn once a day.
/// `%N` in a first line stands for the days late (words up to nine, digits
/// from ten).
class _WeeklyReviewRow {
  const _WeeklyReviewRow(this.firsts, this.seconds, this.buttons);
  final List<String> firsts;
  final List<String> seconds;
  final List<String> buttons;
}

// Every second line says that a short session is enough (design canvas pool,
// given by the board owner). Buttons are Bertie speak: they answer Jeeves, so
// they never name the Ceremony.
const _wrDueDay = _WeeklyReviewRow(
  [
    'The Weekly Review is due, sir.',
    'Review day, sir.',
    'The week wants its review, sir.',
  ],
  [
    'Today. A short sitting will do.',
    'Fifteen minutes would settle it.',
    'Even a short sitting counts.',
  ],
  ['Right ho  →', 'Very good  →', 'Indeed  →'],
);

const _wrOneDayLate = _WeeklyReviewRow(
  [
    'The Weekly Review, sir. A day late.',
    'Yesterday’s review, sir, by my book.',
  ],
  ['No harm done, if we are quick.', 'A short sitting puts it right.'],
  ['At once  →', 'Right ho  →'],
);

const _wrTwoToNineDaysLate = _WeeklyReviewRow(
  [
    'The Weekly Review, sir. %N days late.',
    '%N days past the review, sir.',
  ],
  [
    'A short sitting settles it.',
    'The lists do not audit themselves.',
    'One hesitates to mention it. Fifteen minutes?',
  ],
  ['Quite  →', 'Indeed  →', 'Very good  →'],
);

/// Joins the pool only at exactly seven days late.
const _wrAWeekLateFirstLine = 'A week without a review, sir.';

const _wrTenOrMoreDaysLate = _WeeklyReviewRow(
  [
    'The Weekly Review, sir. %N days late.',
    '%N days without a review, sir. I kept count.',
  ],
  [
    'A short sitting still counts.',
    'Quarter of an hour would do nicely.',
  ],
  ['Quite  →', 'Right ho  →'],
);

const _wrUnfinished = _WeeklyReviewRow(
  [
    'The Weekly Review, sir. Unfinished.',
    'We left the review half done, sir.',
    'Half a review, sir.',
  ],
  [
    'Shall we go on where we left off?',
    'It keeps, but only just.',
    'The rest awaits.',
  ],
  ['Push on  →', 'Carry on  →', 'On we go  →'],
);

/// Content-state Trigger lines: the review is not late, Next and Inbox are
/// empty, and Waiting For or Someday/Maybe still hold items. One pair is
/// drawn per day.
const kWeeklyReviewContentStateLinePair = <(String, String)>[
  ('Nothing on Next, sir.', 'A short review would find the next thing.'),
  (
    'Nothing to be getting on with, sir.',
    'Fifteen minutes with the lists would mend that.',
  ),
  (
    'All quiet, sir. Rather too quiet.',
    'Waiting For and Someday/Maybe want a short look.',
  ),
];

const _smallNumberWords = <String>[
  'Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight',
  'Nine',
];

_WeeklyReviewRow _rowForDaysLate(int daysLate) {
  if (daysLate <= 0) return _wrDueDay;
  if (daysLate == 1) return _wrOneDayLate;
  if (daysLate < 10) return _wrTwoToNineDaysLate;
  return _wrTenOrMoreDaysLate;
}

String _firstLineFor(int daysLate, int seed) {
  final row = _rowForDaysLate(daysLate);
  final firsts = [
    ...row.firsts,
    if (daysLate == 7) _wrAWeekLateFirstLine,
  ];
  final count = daysLate < 10 ? _smallNumberWords[daysLate.clamp(0, 9)] : '$daysLate';
  return firsts[seed % firsts.length].replaceAll('%N', count);
}

/// The Weekly Review's first line for [daysLate]; [seed] picks from the pool
/// (seed 0 is the canonical line).
String weeklyReviewFirstLine(int daysLate, {int seed = 0}) =>
    _firstLineFor(daysLate, seed);

_Quip _weeklyReviewQuip({
  required DateTime now,
  required bool unfinished,
  required int? daysLate,
}) {
  final seed = _dailySeed(now);
  if (daysLate == null && !unfinished) {
    // Only the content-state Trigger is firing: the review is not late.
    final pair = kWeeklyReviewContentStateLinePair[
        seed % kWeeklyReviewContentStateLinePair.length];
    return _Quip(pair.$1, pair.$2, _wrDueDay.buttons[seed % _wrDueDay.buttons.length]);
  }
  final row = unfinished ? _wrUnfinished : _rowForDaysLate(daysLate!);
  final title = unfinished
      ? row.firsts[seed % row.firsts.length]
      : _firstLineFor(daysLate!, seed);
  return _Quip(
    title,
    row.seconds[seed % row.seconds.length],
    row.buttons[seed % row.buttons.length],
  );
}

// ---------------------------------------------------------------------------
// Banner chrome — shared between all Rituals, parametrised by [_Skin].
// ---------------------------------------------------------------------------

class _BannerContent extends StatefulWidget {
  const _BannerContent({
    super.key,
    required this.skin,
    required this.quip,
    required this.onTap,
    required this.onDismiss,
  });

  final _Skin skin;
  final _Quip quip;
  final VoidCallback onTap;
  /// Null for a Banner that cannot be dismissed (Inbox too full).
  final VoidCallback? onDismiss;

  @override
  State<_BannerContent> createState() => _BannerContentState();
}

/// Horizontal travel, in logical pixels, that counts as a swipe-dismiss.
const double _kSwipeDismissDistance = 80;

/// Horizontal fling speed that counts as a swipe-dismiss on its own.
const double _kSwipeDismissVelocity = 700;

class _BannerContentState extends State<_BannerContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: widget.skin.pulseDuration);
    if (widget.skin.pulses) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _finishDrag(DragEndDetails details) {
    final travelled = _dragOffset.abs();
    setState(() => _dragOffset = 0);
    if (travelled >= _kSwipeDismissDistance ||
        details.velocity.pixelsPerSecond.dx.abs() >= _kSwipeDismissVelocity) {
      widget.onDismiss?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skin;
    final content = Container(
      decoration: BoxDecoration(
        color: skin.bg,
        border: Border(bottom: BorderSide(color: Color(skin.borderTint))),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              ScaleTransition(
                scale: Tween<double>(
                  begin: skin.pulseFromScale,
                  end: skin.pulseToScale,
                ).animate(
                  CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                ),
                child: Icon(skin.icon, size: 22, color: skin.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.quip.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: skin.ink,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.quip.sub,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: skin.inkMuted,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _CtaPill(
                label: widget.quip.cta,
                color: skin.accent,
                onTap: widget.onTap,
              ),
            ],
          ),
        ),
      ),
    );
    final onDismiss = widget.onDismiss;
    if (onDismiss == null) {
      return GestureDetector(onTap: widget.onTap, child: content);
    }
    return CallbackShortcuts(
      // Keyboard dismissal: Escape or Delete while a Banner control has focus.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
        const SingleActivator(LogicalKeyboardKey.delete): onDismiss,
      },
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Dismiss'): onDismiss,
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onHorizontalDragUpdate: (details) =>
              setState(() => _dragOffset += details.delta.dx),
          onHorizontalDragCancel: () => setState(() => _dragOffset = 0),
          onHorizontalDragEnd: _finishDrag,
          child: Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: content,
          ),
        ),
      ),
    );
  }
}

class _CtaPill extends StatelessWidget {
  const _CtaPill({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(2),
      child: InkWell(
        borderRadius: BorderRadius.circular(2),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
