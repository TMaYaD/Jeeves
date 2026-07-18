/// The two non-data surfaces shared by [AsyncList] (list-bound screens) and
/// [AsyncSubject] (single-row screens).
///
/// Kept in one place so an error or empty/missing state looks the same
/// whichever async shape produced it. Neither surface renders a spinner —
/// loading is a plain centred [CircularProgressIndicator] at both callsites.
///
/// [ErrorSurface] carries the invariant that error copy never leaks raw
/// exception text at the user: the detail goes to `debugPrint` in the builder
/// that renders this, the user sees fixed copy.
library;

import 'package:flutter/material.dart';

/// Fixed, non-leaking error copy. Deliberately takes no message argument —
/// exception text is for the log, not the screen.
class ErrorSurface extends StatelessWidget {
  const ErrorSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Something went wrong. Please try again.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF9CA3AF)),
        ),
      ),
    );
  }
}

/// Icon + title (+ optional subtitle and CTA) panel, used for both a list's
/// *empty* state and a subject's *missing* state.
class EmptySurface extends StatelessWidget {
  const EmptySurface({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.cta,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? cta;

  @override
  Widget build(BuildContext context) {
    return Center(
      // Scrollable so the panel survives being squeezed — large accessibility
      // text on a short viewport otherwise overflows and pushes [cta] off the
      // bottom, which on a *missing* state means the user's only way out is
      // unreachable. Under the loose constraints [Center] gives it, the scroll
      // view shrink-wraps its content, so a panel that fits stays centred and
      // only an oversized one starts scrolling.
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 48, color: const Color(0xFFD1D5DB)),
              const SizedBox(height: 12),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF6B7280)),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 13,
                ),
              ),
            ],
            if (cta != null) ...[
              const SizedBox(height: 16),
              cta!,
            ],
          ],
        ),
      ),
    );
  }
}
