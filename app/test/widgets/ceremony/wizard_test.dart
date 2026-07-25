/// Widget tests for the shared [Wizard] / [WizardStep] abstraction and
/// the footer widgets shipped alongside it (Issue #322).
///
/// These tests exercise the Wizard shell and the [WizardFooter] /
/// [ListItemFooter] / [BackOnlyFooter] contracts in isolation — no ritual
/// notifier, no Drift database — so they validate the contract from
/// `docs/DESIGN.md` (one forward affordance, Skip secondary, Next step
/// primary in accent) and `docs/REQUIREMENTS.md:72` (per-item cursor
/// advances first; crossing only on the last item).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/capture/capture_sheet.dart';
import 'package:jeeves/widgets/ceremony/wizard.dart';

const _ceremonyId = 'test_ritual';
const _skipKey = Key('test_ritual_skip');
const _nextKey = Key('test_ritual_next_step');
const _slotKey = Key('test_ritual_footer_slot');
const _backKey = Key('test_ritual_back');

const _accent = Color(0xFF2563EB);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Convenience builder for a wizard whose currentStep is mutable via the
/// harness's [setStep]. Mirrors the production wiring: an external
/// source-of-truth (the ritual notifier) holds the step index; the wizard
/// reflects it.
class _Harness extends StatefulWidget {
  const _Harness({required this.buildSteps});

  /// Builder so the steps can read the harness's current step / setState
  /// when wiring footer callbacks.
  final List<WizardStep> Function(int currentStep, void Function(int) setStep)
      buildSteps;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int _step = 0;

  void _setStep(int s) {
    setState(() => _step = s);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Wizard(
        ceremonyLabel: 'Test Ritual',
        ceremonyIcon: Icons.star,
        accentColor: _accent,
        currentStep: _step,
        steps: widget.buildSteps(_step, _setStep),
      ),
    );
  }
}

void main() {
  group('WizardFooter — primary Next step affordance', () {
    testWidgets('renders Next step in the supplied accent', (tester) async {
      const accent = Color(0xFF059669); // Weekly Review green
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: accent,
        onBack: null,
        onNext: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);
      expect(find.text('Next step'), findsOneWidget);

      final button = tester.widget<FilledButton>(find.byKey(_nextKey));
      final bg = button.style!.backgroundColor!.resolve(const {});
      expect(bg, accent);
    });

    testWidgets('renders a custom nextLabel under the same next_step key',
        (tester) async {
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: () {},
        nextLabel: 'Right ho',
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.text('Right ho'), findsOneWidget);
      expect(find.text('Next step'), findsNothing);
    });

    testWidgets('renders the longest Bertie label in full, no ellipsis',
        (tester) async {
      // "Tinkerty-tonk" is the longest label in the intro CTA pool; it must
      // fit the fixed 148px slot without truncation (the footer shrinks-to-fit
      // rather than clipping the word).
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: () {},
        nextLabel: 'Tinkerty-tonk',
      )));
      await tester.pumpAndSettle();

      expect(find.text('Tinkerty-tonk'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('Tinkerty-tonk'));
      expect(textWidget.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets('defaults nextLabel to "Next step"', (tester) async {
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Next step'), findsOneWidget);
    });

    testWidgets('Next step is disabled when onNext is null', (tester) async {
      await tester.pumpWidget(_wrap(const WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: null,
      )));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byKey(_nextKey)).onPressed,
        isNull,
      );
    });

    testWidgets('renders Back only when onBack is non-null', (tester) async {
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(_backKey), findsNothing);

      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: () {},
        onNext: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(_backKey), findsOneWidget);
    });

    testWidgets('tapping Next step invokes onNext', (tester) async {
      var hits = 0;
      await tester.pumpWidget(_wrap(WizardFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onNext: () => hits++,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_nextKey));
      await tester.pumpAndSettle();

      expect(hits, 1);
    });
  });

  group('ListItemFooter — Skip / Next-step swap', () {
    testWidgets('renders Skip while hasMoreItems is true', (tester) async {
      await tester.pumpWidget(_wrap(ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onSkip: () {},
        onNext: () {},
        hasMoreItems: true,
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_skipKey), findsOneWidget);
      expect(find.byKey(_nextKey), findsNothing);
      expect(find.text('Skip'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_skipKey)).onPressed,
        isNotNull,
      );
    });

    testWidgets('swaps Skip → Next step when hasMoreItems flips false',
        (tester) async {
      var hasMore = true;
      late StateSetter setOuter;
      await tester.pumpWidget(_wrap(StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return ListItemFooter(
            ceremonyId: _ceremonyId,
            accentColor: _accent,
            onBack: null,
            onSkip: () {},
            onNext: () {},
            hasMoreItems: hasMore,
          );
        },
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(_skipKey), findsOneWidget);

      setOuter(() => hasMore = false);
      await tester.pumpAndSettle();

      expect(find.byKey(_nextKey), findsOneWidget);
      expect(find.byKey(_skipKey), findsNothing);
    });

    testWidgets('the forward slot keeps a fixed footprint across the swap',
        (tester) async {
      var hasMore = true;
      late StateSetter setOuter;
      await tester.pumpWidget(_wrap(StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return ListItemFooter(
            ceremonyId: _ceremonyId,
            accentColor: _accent,
            onBack: null,
            onSkip: () {},
            onNext: () {},
            hasMoreItems: hasMore,
          );
        },
      )));
      await tester.pumpAndSettle();
      final skipSize = tester.getSize(find.byKey(_slotKey));

      setOuter(() => hasMore = false);
      await tester.pumpAndSettle();

      final nextSize = tester.getSize(find.byKey(_slotKey));
      expect(nextSize, skipSize);
    });

    testWidgets('Next step is disabled once the cursor is spent and '
        'onNext is null (loading)', (tester) async {
      await tester.pumpWidget(_wrap(ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onSkip: () {},
        onNext: null,
        hasMoreItems: false,
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_nextKey), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(_nextKey)).onPressed,
        isNull,
      );
    });

    testWidgets('tapping Skip invokes onSkip, not onNext', (tester) async {
      var skipped = 0;
      var advanced = 0;
      await tester.pumpWidget(_wrap(ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onSkip: () => skipped++,
        onNext: () => advanced++,
        hasMoreItems: true,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_skipKey));
      await tester.pumpAndSettle();

      expect(skipped, 1);
      expect(advanced, 0);
    });

    testWidgets('tapping Next step invokes onNext when the cursor is spent',
        (tester) async {
      var advanced = 0;
      await tester.pumpWidget(_wrap(ListItemFooter(
        ceremonyId: _ceremonyId,
        accentColor: _accent,
        onBack: null,
        onSkip: () {},
        onNext: () => advanced++,
        hasMoreItems: false,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_nextKey));
      await tester.pumpAndSettle();

      expect(advanced, 1);
    });

    group('Back button routing', () {
      // The footer only sees onBack: non-null renders a Back button that invokes
      // the callback on tap; whether that callback maps to previous() or
      // goToStep(currentStep - 1) is the caller's decision, not this widget's.
      // The null-onBack (Back-absent) case is covered by WizardFooter's
      // 'renders Back only when onBack is non-null' above.
      testWidgets('tapping Back invokes the supplied onBack callback',
          (tester) async {
        var backCalls = 0;

        await tester.pumpWidget(_wrap(ListItemFooter(
          ceremonyId: _ceremonyId,
          accentColor: _accent,
          onBack: () => backCalls++,
          onSkip: () {},
          onNext: () {},
          hasMoreItems: false,
        )));
        await tester.pumpAndSettle();

        expect(find.byKey(_backKey), findsOneWidget);
        await tester.tap(find.byKey(_backKey));
        await tester.pumpAndSettle();

        expect(backCalls, 1);
      });
    });
  });

  group('BackOnlyFooter', () {
    testWidgets('renders no forward affordance, only Back when onBack is set',
        (tester) async {
      await tester.pumpWidget(_wrap(BackOnlyFooter(
        ceremonyId: _ceremonyId,
        onBack: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(_backKey), findsOneWidget);
      expect(find.byKey(_slotKey), findsNothing);
      expect(find.byKey(_nextKey), findsNothing);
      expect(find.byKey(_skipKey), findsNothing);
    });
  });

  group('Wizard chrome', () {
    testWidgets('renders the ritual label, step title, and step counter',
        (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
          WizardStep(title: 'Review Things', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Test Ritual'), findsOneWidget);
      expect(find.text('Process Inbox'), findsOneWidget);
      expect(find.text('Step 1 of 2'), findsOneWidget);
    });

    testWidgets(
        'carries the ceremony label + icon as the bar overline, step title as '
        'the bar title, and no leading affordance', (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
          WizardStep(title: 'Review Things', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.title, 'Process Inbox');
      expect(bar.overline?.label, 'Test Ritual');
      expect(bar.overline?.icon, Icons.star);
      expect(bar.leading, AppTitleBarLeading.none);
      // Ceremonies own their guarded exit — the bar renders no leading button.
      expect(find.byKey(appTitleBarLeadingKey), findsNothing);
    });

    testWidgets('pins the global capture action in the bar mid-ceremony (#458)',
        (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      final bar = tester.widget<AppTitleBar>(find.byType(AppTitleBar));
      expect(bar.pinnedAction?.key, const Key('capture_action'));
      expect(find.byKey(const Key('capture_action')), findsOneWidget);
    });

    testWidgets(
        'capturing mid-ceremony via the pinned action leaves currentStep and '
        'the route untouched (#458 hygiene)', (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
          WizardStep(title: 'Review Things', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Process Inbox'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CaptureSheet), findsOneWidget);

      // Dismiss by tapping the modal scrim above the sheet — no submit, no
      // navigation.
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CaptureSheet), findsNothing);

      // Opening/dismissing capture is a modal overlay, never a route push or
      // step-cursor advance (ADR-0009 hygiene): the wizard is still mounted
      // on the same step it started on.
      expect(find.byType(Wizard), findsOneWidget);
      expect(find.text('Process Inbox'), findsOneWidget);
    });

    testWidgets('renders the progress narration below the bar', (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
          WizardStep(title: 'Review Things', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      final barBottom =
          tester.getRect(find.byType(AppTitleBar)).bottom;
      final narration = tester.getTopLeft(find.text('Step 1 of 2')).dy;
      expect(narration, greaterThanOrEqualTo(barBottom),
          reason: 'the progress bar + narration sit in the content region, '
              'flush beneath the bar');
    });

    testWidgets('uses the step.subtitle when provided', (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(
            title: 'Inbox',
            body: SizedBox.shrink(),
            subtitle: 'Step 1 of 5 · 2 / 5 processed',
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Step 1 of 5 · 2 / 5 processed'), findsOneWidget);
      expect(find.text('Step 1 of 1'), findsNothing);
    });

    testWidgets('renders no footer for a step with footer: null',
        (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (_, _) => const [
          WizardStep(title: 'Body-only', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      // No footer widget → no Back / Next / Skip rendered.
      expect(find.byKey(_backKey), findsNothing);
      expect(find.byKey(_nextKey), findsNothing);
      expect(find.byKey(_skipKey), findsNothing);
    });

    testWidgets(
        'absorbs footer taps while the page transition is animating '
        '(issue #180, Gap 3)', (tester) async {
      // Three steps whose footers all advance. A second tap landing on the
      // next step's identically-positioned Next button during the 300 ms
      // transition must be absorbed — exactly one step advances per tap.
      await tester.pumpWidget(_Harness(
        buildSteps: (currentStep, setStep) => List.generate(
          3,
          (i) => WizardStep(
            title: 'Step $i',
            body: const SizedBox.shrink(),
            footer: WizardFooter(
              ceremonyId: _ceremonyId,
              accentColor: _accent,
              onBack: null,
              onNext: () => setStep(i + 1),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_nextKey));
      // Mid-transition (~150 ms of the 300 ms animation): the footer slot is
      // already showing step 1's Next button at the same screen position.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(find.byKey(_nextKey), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Step 1'), findsOneWidget,
          reason: 'the mid-transition tap is absorbed');
      expect(find.text('Step 2'), findsNothing);

      // Once the transition settles, the footer accepts taps again.
      await tester.tap(find.byKey(_nextKey));
      await tester.pumpAndSettle();
      expect(find.text('Step 2'), findsOneWidget);
    });

    testWidgets('updates the header title when currentStep changes externally',
        (tester) async {
      await tester.pumpWidget(_Harness(
        buildSteps: (currentStep, setStep) => [
          WizardStep(
            title: 'Step Alpha',
            body: const SizedBox.shrink(),
            footer: WizardFooter(
              ceremonyId: _ceremonyId,
              accentColor: _accent,
              onBack: null,
              onNext: () => setStep(1),
            ),
          ),
          const WizardStep(title: 'Step Beta', body: SizedBox.shrink()),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Step Alpha'), findsOneWidget);
      expect(find.text('Step Beta'), findsNothing);

      await tester.tap(find.byKey(_nextKey));
      await tester.pumpAndSettle();

      expect(find.text('Step Alpha'), findsNothing);
      expect(find.text('Step Beta'), findsOneWidget);
    });
  });

  group('Wizard — leadingNonProgressSteps (intro step, #486)', () {
    // A wizard with one leading non-progress step (the intro) and four
    // numbered working steps behind it. currentStep is fixed per pump.
    Widget wizardAt(int currentStep) => MaterialApp(
          home: Wizard(
            ceremonyLabel: 'Test Ritual',
            ceremonyIcon: Icons.star,
            accentColor: _accent,
            currentStep: currentStep,
            progressSegmentCount: 4,
            leadingNonProgressSteps: 1,
            steps: const [
              // Intro: explicit empty subtitle suppresses the step counter.
              WizardStep(title: 'Before we begin', body: SizedBox.shrink(),
                  subtitle: ''),
              WizardStep(title: 'Process Inbox', body: SizedBox.shrink()),
              WizardStep(title: 'Waiting For', body: SizedBox.shrink()),
              WizardStep(title: 'Next Actions', body: SizedBox.shrink()),
              WizardStep(title: 'Someday/Maybe', body: SizedBox.shrink()),
            ],
          ),
        );

    testWidgets('on the intro no "Step N of M" counter renders', (tester) async {
      await tester.pumpWidget(wizardAt(0));
      await tester.pumpAndSettle();

      // The intro is not a numbered step: neither its own (would-be) counter
      // nor the first working step's counter appears.
      expect(find.textContaining('Step 1 of 4'), findsNothing);
      expect(find.textContaining(RegExp(r'Step \d of 4')), findsNothing);
      expect(find.text('Before we begin'), findsOneWidget);
    });

    testWidgets('the first working step reads "Step 1 of 4"', (tester) async {
      await tester.pumpWidget(wizardAt(1));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 4'), findsOneWidget);
    });

    testWidgets('the last working step reads "Step 4 of 4"', (tester) async {
      await tester.pumpWidget(wizardAt(4));
      await tester.pumpAndSettle();
      expect(find.text('Step 4 of 4'), findsOneWidget);
    });
  });
}
