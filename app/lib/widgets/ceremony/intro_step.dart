/// The duration-estimate intro step shared by the Daily Planning and Weekly
/// Review ceremonies (Issue #486).
///
/// A single informational first step (index 0 in each wizard's [PageView]),
/// excluded from the progress-segment count via
/// [Wizard.leadingNonProgressSteps]. It sets expectations for the ritual
/// ahead: one Jeeves-speak sentence (DESIGN.md § Voice) with the time estimate
/// rendered inline as a bold, larger, accent-coloured run — the scannable
/// focal point lives *inside* the sentence, not stacked above it.
///
/// The estimate is an approximation by design: 2 minutes per item to be
/// walked, plus (Daily Planning only) a flat 5 minutes for the Energy/Time
/// check-ins and task selection. It is rounded up to the nearest 5 and floored
/// at 5, so the intro always shows a scannable time — a zero-item Weekly
/// Review reads "about 5 minutes", never "0". The counts recompute run-to-run
/// from the current lists.
///
/// The proceed CTA is Bertie speak (the user answering Jeeves) — see
/// [introCtaLabel]; it rides [WizardFooter.nextLabel] and is always enabled,
/// as advancing is never gated on the estimate query.
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../jeeves_logo.dart';

// ---------------------------------------------------------------------------
// Estimate model
// ---------------------------------------------------------------------------

/// The estimate feeding the intro body. Loading until the ceremony's counts
/// are available; ready once they are.
sealed class IntroEstimate {
  const IntroEstimate();
}

/// Counts are still being read — the body shows a quiet placeholder while the
/// user may proceed regardless (the CTA never waits on this).
class IntroEstimateLoading extends IntroEstimate {
  const IntroEstimateLoading();
}

/// Counts are in. [rawMinutes] is the ceremony-specific pre-rounding estimate
/// (Daily Planning adds a flat 5; Weekly Review does not); [itemCount] is the
/// total number of items to be walked — zero selects the light-day copy.
class IntroEstimateReady extends IntroEstimate {
  const IntroEstimateReady({required this.rawMinutes, required this.itemCount});

  final int rawMinutes;
  final int itemCount;
}

// ---------------------------------------------------------------------------
// Duration display
// ---------------------------------------------------------------------------

/// The display duration in minutes: [rawMinutes] rounded **up** to the nearest
/// 5, floored at 5. The floor guarantees the intro always shows a scannable
/// time (a zero-item Weekly Review reads "about 5 minutes"); the round-up
/// hides the falsely-precise odd numbers `2×n (+5)` produces.
int introDisplayMinutes(int rawMinutes) {
  final roundedUpToNearest5 = ((rawMinutes + 4) ~/ 5) * 5;
  return roundedUpToNearest5 < 5 ? 5 : roundedUpToNearest5;
}

/// The whole "about N minutes" run that fills a copy template's `{duration}`
/// slot. The floor makes the singular ("about 1 minute") unreachable, but it
/// is handled grammatically all the same.
String introDurationText(int rawMinutes) {
  final minutes = introDisplayMinutes(rawMinutes);
  return minutes == 1 ? 'about 1 minute' : 'about $minutes minutes';
}

// ---------------------------------------------------------------------------
// Copy pools (Jeeves speak) — first person, "sir", dry, no exclamation marks,
// no emoji. `{duration}` expands to the whole "about N minutes" run, which
// renders as the bold/larger/accent focal point inside the sentence.
// ---------------------------------------------------------------------------

/// Daily Planning intro body pool.
const dprIntroBodyPool = <String>[
  "Shall we set the day to rights, sir? I should think {duration} will see us "
      "through.",
  "A moment to order the day — {duration} or thereabouts, sir.",
  "Let us take stock of what's before you, sir. {duration}, at my estimate.",
  "The day awaits arrangement, sir. I make it {duration}.",
];

/// Weekly Review intro body pool.
const wrIntroBodyPool = <String>[
  "The week in review, sir — I should allow {duration}.",
  "Time to survey the week's estate. {duration}, by my reckoning.",
  "Shall we take the longer view, sir? {duration} should suffice.",
];

/// Light-day pool, used at zero items by either ceremony. Still shows the
/// floored `{duration}`.
const introLightDayPool = <String>[
  "A light day, sir — little to trouble you. Done in {duration}.",
  "Scarcely anything outstanding, sir. {duration} and you're free.",
  "The decks are near clear, sir. {duration}, no more.",
];

// ---------------------------------------------------------------------------
// Bertie-speak proceed CTA — the user answering Jeeves (DESIGN.md § Voice).
// Constrained to labels that fit the footer's fixed 148px slot (the footer
// shrinks-to-fit as a backstop for the longest, "Tinkerty-tonk").
// ---------------------------------------------------------------------------

const introCtaPool = <String>[
  'Right ho',
  'Rather!',
  'Pip pip',
  'Tinkerty-tonk',
  'Tally-ho',
  'Off we pop',
];

final _ctaRandom = Random();

/// Draws a Bertie-speak proceed label. Pass [seed] in tests for a
/// deterministic draw; null in production so each performance draws afresh.
String introCtaLabel({int? seed}) {
  final rng = seed == null ? _ctaRandom : Random(seed);
  return introCtaPool[rng.nextInt(introCtaPool.length)];
}

// ---------------------------------------------------------------------------
// Body widget
// ---------------------------------------------------------------------------

/// The intro step's body: a Jeeves logo above one Jeeves-speak sentence, the
/// estimate rendered inline as a bold, larger, accent-coloured run.
///
/// The copy line is drawn once per mount (seedable for tests) and stays stable
/// across the loading→ready rebuild — the `elapsed_timer_widget.dart` /
/// `onboarding_card.dart` seeded-draw idiom named by DESIGN.md § Voice.
class CeremonyIntroBody extends StatefulWidget {
  const CeremonyIntroBody({
    super.key,
    required this.accentColor,
    required this.estimate,
    required this.bodyPool,
    required this.lightDayPool,
    this.seed,
  });

  /// The ceremony accent — colours the inline duration run.
  final Color accentColor;

  /// Loading | ready(rawMinutes, itemCount).
  final IntroEstimate estimate;

  /// Templates (with a `{duration}` slot) used when there are items to walk.
  final List<String> bodyPool;

  /// Templates used at zero items — still shows the floored `{duration}`.
  final List<String> lightDayPool;

  /// Deterministic seed for the copy draw, used by tests. Null in production.
  final int? seed;

  @override
  State<CeremonyIntroBody> createState() => _CeremonyIntroBodyState();
}

class _CeremonyIntroBodyState extends State<CeremonyIntroBody> {
  static const _ink = Color(0xFF374151);

  /// A single draw taken once per mount, indexed (modulo pool length) into
  /// whichever pool applies at build time. Storing the raw draw — rather than
  /// a pool index — keeps the line stable across the loading→ready rebuild,
  /// where the applicable pool (and its length) may change.
  late final int _draw =
      (widget.seed == null ? Random() : Random(widget.seed!)).nextInt(1 << 31);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const JeevesLogo(size: 48, variant: JeevesLogoVariant.signature),
            const SizedBox(height: 28),
            _buildSentence(),
          ],
        ),
      ),
    );
  }

  Widget _buildSentence() {
    const baseStyle = TextStyle(
      fontSize: 20,
      height: 1.5,
      fontWeight: FontWeight.w500,
      color: _ink,
    );

    final estimate = widget.estimate;
    if (estimate is! IntroEstimateReady) {
      // Quiet placeholder while the counts read; the CTA (footer) does not wait.
      return const Text(
        'One moment, sir — I am taking stock.',
        textAlign: TextAlign.center,
        style: baseStyle,
      );
    }

    final pool =
        estimate.itemCount == 0 ? widget.lightDayPool : widget.bodyPool;
    final template = pool[_draw % pool.length];
    final durationText = introDurationText(estimate.rawMinutes);

    // Split the single {duration} slot; the emphasised run spans the whole
    // "about N minutes" substring inside the sentence (visual layout B).
    final parts = template.split('{duration}');
    final durationStyle = baseStyle.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w700,
      color: widget.accentColor,
    );

    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0) TextSpan(text: durationText, style: durationStyle),
            TextSpan(text: parts[i]),
          ],
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
