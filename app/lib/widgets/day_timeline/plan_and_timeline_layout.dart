library;

import 'package:flutter/material.dart';

/// Width, in logical pixels, from which the Plan rows and the day timeline sit
/// side by side. Below it they stack, timeline first.
const double planTimelineWideBreakpointWidth = 840;

/// The Plan rows and the day timeline, each under its own heading.
///
/// Stacked on a narrow screen (timeline, divider, Plan rows); two panes on a
/// wide one (Plan rows left, timeline right). There is no third panel. Meant
/// to sit inside a scroll view: it never expands vertically.
class PlanAndTimelineLayout extends StatelessWidget {
  const PlanAndTimelineLayout({
    super.key,
    required this.timelineHeading,
    required this.timeline,
    required this.planHeading,
    required this.planChildren,
  });

  final String timelineHeading;
  final Widget timeline;
  final String planHeading;
  final List<Widget> planChildren;

  static const _headingStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: Color(0xFF1A1A2E),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= planTimelineWideBreakpointWidth;
        final timelinePane = <Widget>[
          Text(timelineHeading, style: _headingStyle),
          const SizedBox(height: 16),
          timeline,
        ];
        final planPane = <Widget>[
          Text(planHeading, style: _headingStyle),
          const SizedBox(height: 16),
          ...planChildren,
        ];
        if (isWide) {
          return Row(
            key: const ValueKey('plan-timeline-two-panes'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: planPane,
                ),
              ),
              const SizedBox(width: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: timelinePane,
                ),
              ),
            ],
          );
        }
        return Column(
          key: const ValueKey('plan-timeline-stacked'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...timelinePane,
            const SizedBox(height: 36),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            const SizedBox(height: 36),
            ...planPane,
          ],
        );
      },
    );
  }
}
