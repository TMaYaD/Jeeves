import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state_surfaces.dart';

/// Builder that renders the standard loading / error / empty / data surfaces
/// for an [AsyncValue] holding a list.
///
/// Owns the visual contract shared by every GTD list screen (Inbox,
/// Next Actions, Waiting For, Someday-Maybe, Search): a centered spinner
/// while loading; a friendly error message that never leaks raw exception
/// text; an empty-state container with an icon, a per-callsite title, an
/// optional subtitle and an optional CTA.
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
    // Branched explicitly rather than through `AsyncValue.when`, which cannot
    // express this order. Riverpod 3 auto-retries a failed provider, so a
    // stream error does not arrive as `AsyncError` — it arrives as
    // `AsyncLoading` *carrying* an error, and `when` returns its loading
    // branch for any loading state that is not a refresh/reload. Delegating
    // would therefore render an indefinite spinner for an errored list, and
    // would *also* replace a list the user is already reading with a spinner
    // the moment its watch errors or reloads.
    //
    // Order is error → loading → empty → data, which is exactly what
    // [AsyncSubject] does; see *Async surfaces* in ARCHITECTURE.md. A watch
    // that still holds rows is exempt from both the error and the loading
    // surface: showing the last known rows beats blanking them mid-retry.
    //
    // That exemption is keyed on having rows to *show*, not merely on
    // `hasValue`. A watch that emitted `[]` and then errored retains the empty
    // list, so a bare `hasValue` test would skip this branch and render
    // "nothing here yet" — reporting an empty list when the truth is that the
    // read failed, which makes an empty inbox indistinguishable from a broken
    // one. An empty retained value has nothing worth preserving.
    final hasRenderableRows =
        asyncValue.hasValue && asyncValue.value!.isNotEmpty;
    if (asyncValue.hasError && !hasRenderableRows) {
      debugPrint(
          'AsyncList error: ${asyncValue.error}\n${asyncValue.stackTrace}');
      return const ErrorSurface();
    }
    if (!asyncValue.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = asyncValue.value!;
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
  }
}
