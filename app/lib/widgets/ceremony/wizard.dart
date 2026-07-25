/// The wizard shell shared by Jeeves' three Ceremonies — Daily Planning,
/// Evening Shutdown, and Weekly Review (Issue #322).
///
/// A [Wizard] composes a list of [WizardStep]s and owns the chrome that the
/// three Ceremonies previously open-coded in parallel:
///
/// - The shared [AppTitleBar] (ADR-0021): the ceremony label + icon render as
///   the bar's overline, the current step title as the bar title, and the
///   leading slot is `none` (ceremonies own their own guarded exit).
/// - The step's segmented progress bar and its narration (subtitle), rendered
///   in the wizard's content region flush beneath the bar.
/// - The non-swipeable [PageView] that hosts the step bodies and animates
///   between them whenever [currentStep] changes.
///
/// The wizard does **not** own the footer. Each step renders its own
/// forward affordance through [WizardStep.footer] — typically one of the
/// shared widgets shipped alongside the wizard:
///
/// - [WizardFooter] — Back + a single primary `Next step` button. The
///   default for steps where the user advances by tapping a footer
///   affordance once their input is settled (Energy, Time, Plan Summary,
///   completed-review screens).
/// - [ListItemFooter] — Back + a `Skip` (secondary) / `Next step` (primary)
///   swap inside a fixed-size slot, internalising the per-item-cursor
///   contract that previously leaked into the wizard. Used by every
///   list-driven step (Inbox, Task Review, Waiting For, Next Actions,
///   Someday/Maybe).
///
/// Steps that drive advance entirely from in-body actions (Evening
/// Shutdown's "Resolve Unfinished" — dispositions on each task advance the
/// cursor and the ceremony itself) pass a footer with no forward affordance,
/// or [WizardStep.footer] set to null to render nothing.
///
/// Terminal/completion screens (Daily Planning's "Today's Schedule",
/// Periodic Review's "Review Complete", Evening Shutdown's Close Day) are
/// **not** wizard steps. They are post-ceremony confirmations rendered
/// outside the wizard by their ceremony screen widget; the wizard only ever
/// hosts steps the user actively walks through.
///
/// The wizard does not know about Riverpod providers, Ceremony notifiers,
/// or snapshot navigation. Ceremony screens compose [WizardStep] instances;
/// the step's footer widget (e.g. [WizardFooter], [ListItemFooter]) holds
/// the step-transition callbacks.
library;

import 'package:flutter/material.dart';

import '../app_title_bar/app_title_bar.dart';
import '../capture/capture_action.dart';

/// One step of a [Wizard]. Carries display metadata and the widget tree
/// for the step body and its footer.
///
/// A step with [footer] `null` renders no footer at all — used by steps
/// whose body fills the wizard area on its own.
class WizardStep {
  const WizardStep({
    required this.title,
    required this.body,
    this.footer,
    this.activeFraction = 0.0,
    this.subtitle,
  });

  /// Step title rendered in the header (e.g. "Clarify Inbox").
  final String title;

  /// The widget rendered for this step inside the wizard's [PageView].
  final Widget body;

  /// The widget rendered below the body. Typically [WizardFooter] or
  /// [ListItemFooter]; pass `null` to render no footer at all.
  final Widget? footer;

  /// Fill fraction (0.0–1.0) for this step's segment when the wizard is
  /// **on** this step. Future steps render as 0.0; past steps as 1.0;
  /// the wizard reads this only for the active step. List-driven steps
  /// typically expose `nav.index / nav.length`; non-list steps either 0.0
  /// (pending) or 1.0 (the user's input is settled).
  final double activeFraction;

  /// Optional secondary header line (e.g. "Step 2 of 5 · 1 / 3 seen").
  /// When null the wizard falls back to "Step N of M".
  final String? subtitle;
}

/// The wizard shell. Renders header + non-swipeable [PageView] + the
/// active step's footer (if any).
///
/// Animation: whenever [currentStep] changes between widget builds, the
/// internal [PageController] animates to the new page. The wizard never
/// drives step transitions from its own logic — Ceremony screens compose
/// [WizardStep] instances; the step's footer widget (e.g. [WizardFooter],
/// [ListItemFooter]) holds the step-transition callbacks.
///
/// While the page transition is animating, footer taps are absorbed: the
/// footer swaps to the new step's widget the moment [currentStep] changes,
/// so without absorption a second tap would land on the next step's
/// identically-positioned forward button mid-transition (issue #180).
class Wizard extends StatefulWidget {
  const Wizard({
    super.key,
    required this.ceremonyLabel,
    required this.ceremonyIcon,
    required this.accentColor,
    required this.currentStep,
    required this.steps,
    this.progressSegmentCount,
    this.leadingNonProgressSteps = 0,
    this.backgroundColor = Colors.white,
  });

  /// Small uppercase ceremony label rendered above the step title
  /// (e.g. "Daily Planning", "Weekly Review", "Evening Shutdown").
  final String ceremonyLabel;

  /// Icon rendered next to [ceremonyLabel].
  final IconData ceremonyIcon;

  /// Screen accent — drives the segmented progress bar fill. Footers
  /// own their own colour decisions.
  final Color accentColor;

  /// Current step index. Whenever this changes, the wizard animates the
  /// page transition. The ritual's notifier is the source of truth.
  final int currentStep;

  /// All steps in order. The wizard renders one [PageView] page per step.
  final List<WizardStep> steps;

  /// Number of segments to render in the progress bar. Defaults to the
  /// total step count.
  final int? progressSegmentCount;

  /// Number of leading steps that sit *outside* the progress count — an
  /// informational intro (Daily Planning / Weekly Review's duration-estimate
  /// briefing) is a real first [PageView] step but is not one of the numbered
  /// working steps. The wizard derives `progressStep = currentStep -
  /// leadingNonProgressSteps` and drives the segmented bar + "Step N of M"
  /// narration from *that*. While `progressStep < 0` (on a leading step) the
  /// bar renders every segment empty and the "Step N of M" fallback is
  /// suppressed — such a step supplies its own body copy, not a step counter.
  final int leadingNonProgressSteps;

  /// Background colour of the scaffold.
  final Color backgroundColor;

  @override
  State<Wizard> createState() => _WizardState();
}

class _WizardState extends State<Wizard> {
  late final PageController _pageController;

  /// True while the page transition is animating. The footer swaps to the
  /// new step's widget the moment [Wizard.currentStep] changes, putting an
  /// identically-positioned forward button under the user's finger — so the
  /// wizard absorbs footer taps until the transition settles (issue #180).
  bool _transitioning = false;

  /// Monotonic token so an interrupted transition's completion callback
  /// cannot clear [_transitioning] while a newer transition is animating.
  int _transitionToken = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.currentStep);
  }

  @override
  void didUpdateWidget(Wizard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentStep != widget.currentStep &&
        _pageController.hasClients) {
      final token = ++_transitionToken;
      setState(() => _transitioning = true);
      _pageController
          .animateToPage(
            widget.currentStep,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          )
          .whenComplete(() {
        if (mounted && token == _transitionToken) {
          setState(() => _transitioning = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.steps[widget.currentStep];

    final pageView = PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      children: widget.steps.map((s) => s.body).toList(growable: false),
    );

    final segmentCount = widget.progressSegmentCount ?? widget.steps.length;

    // Leading non-progress steps (an intro briefing) sit before the numbered
    // working steps: shift the step index the progress machinery sees so the
    // first working step reads as segment 0 / "Step 1 of M". A negative
    // progressStep marks a leading step — the bar renders empty and the
    // step-counter fallback is suppressed.
    final progressStep = widget.currentStep - widget.leadingNonProgressSteps;

    return Scaffold(
      backgroundColor: widget.backgroundColor,
      // The ceremony label + step title live in the shared bar; the leading
      // slot is `none` because ceremonies own their own guarded exit
      // (CeremonyPopScope) — a bar back would be a second, unguarded way out.
      appBar: AppTitleBar(
        title: step.title,
        overline: AppTitleBarOverline(
          label: widget.ceremonyLabel,
          icon: widget.ceremonyIcon,
          iconColor: widget.accentColor,
        ),
        leading: AppTitleBarLeading.none,
        // Capture is reachable mid-ceremony (#458): the Capture waits in the
        // Inbox, ceremony state and snapshot cursors untouched (ADR-0009).
        pinnedAction: captureAction(context),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _WizardProgress(
              progressStep: progressStep,
              segmentCount: segmentCount,
              activeFraction: step.activeFraction,
              accentColor: widget.accentColor,
              subtitle: step.subtitle,
            ),
            Expanded(child: pageView),
            if (step.footer != null)
              // ExcludeFocus keeps keyboard/assistive-tech activation out of
              // the swapped-in footer for the same window IgnorePointer
              // covers for taps.
              ExcludeFocus(
                excluding: _transitioning,
                child: IgnorePointer(
                  ignoring: _transitioning,
                  child: step.footer!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress — segmented progress bar + narration, flush beneath the shared bar
// ---------------------------------------------------------------------------

class _WizardProgress extends StatelessWidget {
  const _WizardProgress({
    required this.progressStep,
    required this.segmentCount,
    required this.activeFraction,
    required this.accentColor,
    required this.subtitle,
  });

  /// The current step's index *within the numbered working steps* — negative
  /// while the wizard is on a leading non-progress step (see
  /// [Wizard.leadingNonProgressSteps]).
  final int progressStep;
  final int segmentCount;
  final double activeFraction;
  final Color accentColor;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    // On a leading non-progress step the "Step N of M" fallback is meaningless
    // (the intro is not a numbered step). The intro passes an explicit empty
    // subtitle to signal "no step counter"; render nothing at all rather than
    // an awkward blank line. Working steps keep the fallback.
    final String? line;
    if (progressStep < 0) {
      line = (subtitle == null || subtitle!.isEmpty) ? null : subtitle;
    } else {
      line = subtitle ?? 'Step ${progressStep + 1} of $segmentCount';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SegmentedProgressBar(
            currentStep: progressStep,
            segmentCount: segmentCount,
            activeFraction: activeFraction,
            accent: accentColor,
          ),
          const SizedBox(height: 4),
          if (line != null)
            Text(
              line,
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar({
    required this.currentStep,
    required this.segmentCount,
    required this.activeFraction,
    required this.accent,
  });

  final int currentStep;
  final int segmentCount;
  final double activeFraction;
  final Color accent;

  static const Color _empty = Color(0xFFE5E7EB);

  Widget _buildBar(double fraction) {
    if (fraction >= 1.0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    if (fraction <= 0.0) {
      return Container(
        height: 4,
        decoration: BoxDecoration(
          color: _empty,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return Stack(
      children: [
        Container(
          height: 4,
          decoration: BoxDecoration(
            color: _empty,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        FractionallySizedBox(
          widthFactor: fraction,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(segmentCount, (i) {
        final double fraction;
        if (i < currentStep) {
          fraction = 1.0;
        } else if (i == currentStep) {
          fraction = activeFraction.clamp(0.0, 1.0);
        } else if (currentStep >= segmentCount) {
          // Past the last tracked segment — render all filled.
          fraction = 1.0;
        } else {
          fraction = 0.0;
        }
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < segmentCount - 1 ? 4 : 0),
            child: _buildBar(fraction),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared footer widgets — Ceremony screens compose one of these into each
// WizardStep.footer. The wizard itself has no opinion about footer shape.
// ---------------------------------------------------------------------------

/// Fixed slot dimensions so primary/secondary button swaps inside a footer
/// cause no layout shift. Shared between [WizardFooter] and
/// [ListItemFooter] so the "Next step" button is the same shape across
/// every step.
const double _kForwardSlotWidth = 148;
const double _kForwardSlotHeight = 48;

EdgeInsets _footerPadding() => const EdgeInsets.fromLTRB(20, 8, 20, 20);

/// Back-only OutlinedButton, rendered when [onBack] is non-null. Returns
/// `null` so the caller can place it inside a `Row` and let the leading
/// slot collapse when Back is unavailable.
Widget? _backButton({required String ceremonyId, required VoidCallback? onBack}) {
  if (onBack == null) return null;
  return OutlinedButton(
    key: Key('${ceremonyId}_back'),
    onPressed: onBack,
    style: OutlinedButton.styleFrom(
      foregroundColor: const Color(0xFF374151),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
    ),
    child: const Text('Back'),
  );
}

/// Default wizard footer: Back (when [onBack] non-null) on the left, a
/// single primary `Next step` button on the right.
///
/// [onNext] null renders a disabled `Next step`. Used by simple steps
/// where the user advances by tapping a footer affordance once their
/// input is settled (Energy, Time, Plan Summary).
class WizardFooter extends StatelessWidget {
  const WizardFooter({
    super.key,
    required this.ceremonyId,
    required this.accentColor,
    required this.onBack,
    required this.onNext,
    this.nextLabel = 'Next step',
  });

  /// Stable per-Ceremony slug used to namespace widget keys ("planning",
  /// "shutdown", "periodic_review") so tests can locate buttons without
  /// collisions across nested wizards or repeated builds.
  final String ceremonyId;

  /// Primary button background (the screen accent).
  final Color accentColor;

  /// Back handler. Null renders no Back button (typically on step 0).
  final VoidCallback? onBack;

  /// Forward handler. Null renders a disabled `Next step` (typically
  /// while a list-driven step's snapshot is still loading).
  final VoidCallback? onNext;

  /// Label on the primary forward button. Defaults to the neutral
  /// `Next step`; the intro briefing overrides it with a Bertie-speak
  /// affirmative (DESIGN.md § Voice). The label sits in the same fixed
  /// 148×48 slot — [CeremonyIntroBody.introCtaLabel] is drawn from a pool
  /// constrained to fit, and shrinks-to-fit via [FittedBox] if a longer
  /// phrase is ever supplied.
  final String nextLabel;

  @override
  Widget build(BuildContext context) {
    final back = _backButton(ceremonyId: ceremonyId, onBack: onBack);
    return Padding(
      padding: _footerPadding(),
      child: Row(
        children: [
          ?back,
          const Spacer(),
          SizedBox(
            key: Key('${ceremonyId}_footer_slot'),
            width: _kForwardSlotWidth,
            height: _kForwardSlotHeight,
            child: FilledButton(
              key: Key('${ceremonyId}_next_step'),
              onPressed: onNext,
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                disabledBackgroundColor: const Color(0xFFD1D5DB),
                minimumSize:
                    const Size(_kForwardSlotWidth, _kForwardSlotHeight),
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
              ),
              // Shrink-to-fit guards a longer Bertie label (the pool's
              // "Tinkerty-tonk") against overflowing the fixed slot without
              // truncating the word — scaleDown never enlarges the default.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(nextLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Footer for list-driven steps. Renders `Skip` (secondary outlined) while
/// the current step's per-item cursor still has items to consume, swapping
/// in `Next step` (primary, in the screen's accent) once the cursor is on
/// the last item.
///
/// The two are mutually exclusive and swap inside a fixed-size slot so the
/// button's shape, size, and position are identical across the swap. See
/// `docs/DESIGN.md:119–135`.
///
/// Pass [onNext] null to render a disabled `Next step` (snapshot still
/// loading) — Skip is always enabled while visible.
class ListItemFooter extends StatelessWidget {
  const ListItemFooter({
    super.key,
    required this.ceremonyId,
    required this.accentColor,
    required this.onBack,
    required this.onSkip,
    required this.onNext,
    required this.hasMoreItems,
  });

  final String ceremonyId;
  final Color accentColor;

  /// Back handler. Typically wired to retreat the per-item cursor first,
  /// crossing to the previous step once the cursor is at the first item.
  final VoidCallback? onBack;

  /// Skip handler. Should advance the per-item cursor by one.
  final VoidCallback onSkip;

  /// Forward handler — crosses into the next wizard step. Null renders a
  /// disabled `Next step` once the cursor is spent (snapshot still
  /// loading); ignored while [hasMoreItems] is true.
  final VoidCallback? onNext;

  /// True while the cursor still has items beyond the current one;
  /// equivalently, when `Skip` should be visible instead of `Next step`.
  final bool hasMoreItems;

  @override
  Widget build(BuildContext context) {
    final back = _backButton(ceremonyId: ceremonyId, onBack: onBack);
    return Padding(
      padding: _footerPadding(),
      child: Row(
        children: [
          ?back,
          const Spacer(),
          SizedBox(
            key: Key('${ceremonyId}_footer_slot'),
            width: _kForwardSlotWidth,
            height: _kForwardSlotHeight,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: hasMoreItems
                  ? OutlinedButton(
                      key: Key('${ceremonyId}_skip'),
                      onPressed: onSkip,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6B7280),
                        minimumSize: const Size(
                            _kForwardSlotWidth, _kForwardSlotHeight),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 14),
                      ),
                      child: const Text('Skip'),
                    )
                  : FilledButton(
                      key: Key('${ceremonyId}_next_step'),
                      onPressed: onNext,
                      style: FilledButton.styleFrom(
                        backgroundColor: accentColor,
                        disabledBackgroundColor: const Color(0xFFD1D5DB),
                        minimumSize: const Size(
                            _kForwardSlotWidth, _kForwardSlotHeight),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 32, vertical: 14),
                      ),
                      child: const Text('Next step'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Footer for a step that has no forward affordance — only Back.
/// Used by Evening Shutdown's "Resolve Unfinished", where dispositions on
/// each task drive advancement and there is nothing to skip.
class BackOnlyFooter extends StatelessWidget {
  const BackOnlyFooter({
    super.key,
    required this.ceremonyId,
    required this.onBack,
  });

  final String ceremonyId;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final back = _backButton(ceremonyId: ceremonyId, onBack: onBack);
    return Padding(
      padding: _footerPadding(),
      child: Row(
        children: [
          ?back,
          const Spacer(),
        ],
      ),
    );
  }
}
