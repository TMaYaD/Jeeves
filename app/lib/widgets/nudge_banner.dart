/// Single in-app Banner surface for every Ritual's Nudge. Consumes the
/// **Nudge queue** (see `CONTEXT.md`'s **Banner** and **Nudge queue**
/// entries) — renders the highest-priority Ritual whose Nudge is currently
/// visible and whose banner-enabled setting is `true`. Tapping opens the
/// Ceremony; a horizontal swipe maps to a Nudge **dismiss** (current firing).
/// No Banner carries a ✕.
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
import '../providers/shutdown_settings_provider.dart';
import '../providers/system_trust_provider.dart'
    show weeklyReviewDaysLateProvider;

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

class NudgeBanner extends ConsumerWidget {
  const NudgeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ritual = ref.watch(bannerVisibleRitualProvider);
    if (ritual == null) return const SizedBox.shrink();

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

    return _BannerContent(
      key: Key('${ritual.keyPrefix}_banner_visible'),
      skin: skin,
      quip: quip,
      onTap: () => context.go(skin.route),
      onDismiss: () =>
          ref.read(nudgeActionsProvider).dismiss(ritual),
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

// TODO(copy): placeholder. The content-state line pair (Next empty while
// Waiting For or Someday/Maybe hold items; "days late" is untrue there) is
// being written by the Product Owner. The shipped pair stands in until then.
const kWeeklyReviewContentStateLinePair = <(String, String)>[
  ('A weekly tidy, sir?', 'A trifling few minutes keeps the system humming.'),
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
  final VoidCallback onDismiss;

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
    _pulse = AnimationController(vsync: this, duration: widget.skin.pulseDuration)
      ..repeat(reverse: true);
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
      widget.onDismiss();
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
    return CallbackShortcuts(
      // Keyboard dismissal: Escape or Delete while a Banner control has focus.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
        const SingleActivator(LogicalKeyboardKey.delete): widget.onDismiss,
      },
      child: Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Dismiss'): widget.onDismiss,
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
