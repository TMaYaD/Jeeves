import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
///
/// Set [emptyIsScrollable] when an ancestor [RefreshIndicator] needs to fire
/// even on the empty state — that wraps the empty surface in a
/// [ListView] so the gesture has something to drag.
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
    this.emptyIsScrollable = false,
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
  /// matches). When provided, this fully replaces the standard empty layout.
  final WidgetBuilder? emptyBuilder;

  /// When true, the loading / error / empty surfaces render inside a
  /// [ListView] so an enclosing [RefreshIndicator] can fire its gesture
  /// even when there's no data to scroll.
  final bool emptyIsScrollable;

  @override
  Widget build(BuildContext context) {
    return asyncValue.when(
      loading: () => _wrapForScrolling(
        const Center(child: CircularProgressIndicator()),
      ),
      error: (err, stack) {
        debugPrint('AsyncList error: $err\n$stack');
        return _wrapForScrolling(const _ErrorSurface());
      },
      data: (items) {
        if (items.isEmpty) {
          final empty = emptyBuilder != null
              ? emptyBuilder!(context)
              : _EmptySurface(
                  icon: emptyIcon,
                  title: emptyTitle,
                  subtitle: emptySubtitle,
                  cta: emptyCta,
                );
          return _wrapForScrolling(empty);
        }
        return dataBuilder(context, items);
      },
    );
  }

  Widget _wrapForScrolling(Widget child) {
    if (!emptyIsScrollable) return child;
    // A single-child ListView gives a RefreshIndicator something to drag
    // even when the content fits the viewport.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: 400,
          child: child,
        ),
      ],
    );
  }
}

class _ErrorSurface extends StatelessWidget {
  const _ErrorSurface();

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

class _EmptySurface extends StatelessWidget {
  const _EmptySurface({
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
      child: Padding(
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
