import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state_surfaces.dart';

/// Builder that renders the standard loading / error / empty / data surfaces
/// for an [AsyncValue] holding a list.
///
/// Renders every GTD list screen (Inbox, Next Actions, Waiting For,
/// Someday-Maybe, Search) through the shared surfaces in
/// `state_surfaces.dart`: a centered spinner while loading; a friendly error
/// message that never leaks raw exception text; an empty-state container with
/// an icon, a per-callsite title, an optional subtitle and an optional CTA.
/// [AsyncSubject] renders the same three surfaces for a single-row subject, so
/// a list with no rows and a subject whose row is gone look identical.
///
/// The *only* legitimate per-screen variation is empty-state copy and the
/// optional CTA. Pass [emptyBuilder] for the rare case where a callsite
/// needs a fully custom empty surface (e.g. Search's hidden-done hint).
/// When [emptyBuilder] is provided its widget is rendered verbatim — the
/// caller owns scrollability, physics and any [RefreshIndicator] wiring.
class AsyncList<T> extends StatelessWidget {
  const AsyncList({
    super.key,
    required this.asyncValue,
    required this.dataBuilder,
    required this.emptyTitle,
    this.emptyIcon,
    this.emptySubtitle,
    this.emptyCta,
    this.emptyBuilder,
  });

  /// The async list to render.
  final AsyncValue<List<T>> asyncValue;

  /// Renders the list once data is available. Only invoked when the list is
  /// non-empty — empty results are handled by the standard empty surface
  /// (or by [emptyBuilder] when provided).
  final Widget Function(BuildContext context, List<T> items) dataBuilder;

  /// Title shown on the empty state. Required: every list owns its own copy
  /// (e.g. "No tasks waiting for someone", "No tasks in Maybe").
  final String emptyTitle;

  /// Optional icon shown above [emptyTitle].
  final IconData? emptyIcon;

  /// Optional secondary line below [emptyTitle].
  final String? emptySubtitle;

  /// Optional CTA below the empty-state copy (e.g. an "Add task" button).
  final Widget? emptyCta;

  /// Escape hatch for callsites that need a fully custom empty surface
  /// (e.g. Search's "no results" hint with a deep-link to include completed
  /// matches, or the inbox's pull-to-refresh-friendly onboarding card).
  /// When provided, this fully replaces the standard empty layout and is
  /// rendered verbatim — the caller owns scrollability and physics.
  final WidgetBuilder? emptyBuilder;

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      loading: () => const LoadingSurface(),
      error: (err, stack) {
        debugPrint('AsyncList error: $err\n$stack');
        return const ErrorSurface();
      },
      data: (items) {
        if (items.isEmpty) {
          return emptyBuilder != null
              ? emptyBuilder!(context)
              : EmptySurface(
                  icon: emptyIcon,
                  title: emptyTitle,
                  subtitle: emptySubtitle,
                  cta: emptyCta,
                );
        }
        return dataBuilder(context, items);
      },
    );
  }
}
