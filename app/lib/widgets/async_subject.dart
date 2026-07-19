/// Single-row counterpart to [AsyncList].
///
/// Every surface bound to one row — a clarify card's Capture or Outcome, a
/// task detail screen's Outcome — reads an `AsyncValue<T?>` whose null carries
/// two unrelated meanings: "local storage has not answered yet" and "local
/// storage answered, and there is no such row". Collapsing both into
/// `value == null -> spinner` leaves a deleted subject spinning forever, and
/// hides errors behind the same spinner.
///
/// [AsyncSubject] splits them into the four states a subject-bound surface can
/// actually be in, and renders three of them through the shared surfaces in
/// `state_surfaces.dart` so a list with no rows and a subject with no row look
/// identical.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state_surfaces.dart';

class AsyncSubject<T extends Object> extends StatelessWidget {
  const AsyncSubject({
    super.key,
    required this.asyncValue,
    required this.dataBuilder,
    required this.missingTitle,
    this.missingIcon,
    this.missingSubtitle,
    this.missingCta,
    this.missingBuilder,
    this.surfaceWrapper,
  });

  /// The subject to render. Nullable payload by construction: the DAO watch
  /// methods (`CaptureDao.watchCapture`, `TodoDao.watchTodo`) emit null once
  /// the row is gone from local storage.
  final AsyncValue<T?> asyncValue;

  /// Renders the surface once the row is present.
  final Widget Function(BuildContext context, T subject) dataBuilder;

  /// Missing-state headline. Required: every surface owns its own copy.
  final String missingTitle;

  final IconData? missingIcon;
  final String? missingSubtitle;

  /// The way out of the missing state. Supply one wherever the surface has no
  /// route out of its own chrome, so the user is never dead-ended on a subject
  /// that no longer exists.
  final Widget? missingCta;

  /// Escape hatch for a callsite that needs a fully custom missing surface
  /// (e.g. one that must keep its own Scaffold). Replaces the standard layout
  /// verbatim; [missingIcon], [missingSubtitle] and [missingCta] are ignored.
  final WidgetBuilder? missingBuilder;

  /// Chrome placed around the loading / error / missing surfaces, for a
  /// callsite whose [dataBuilder] returns a whole route (its own [Scaffold]).
  /// Without it the three non-data surfaces would render with no app bar and
  /// no background — including no back arrow on the one screen that needs it
  /// most. Never applied to [dataBuilder]'s output.
  final Widget Function(BuildContext context, Widget surface)? surfaceWrapper;

  @override
  Widget build(BuildContext context) {
    final subject = asyncValue.value;
    if (subject != null) {
      // Data before error, deliberately — the one place this diverges from
      // [AsyncList], which routes everything through `when()` and so lets a
      // refresh error replace a rendered list.
      //
      // A subject-bound surface cannot afford that. [dataBuilder] here may
      // return a whole route (see [surfaceWrapper]), so swapping in
      // [ErrorSurface] on a failed background refresh would tear down the
      // open screen — app bar actions, notes, scroll position, the lot — and
      // dead-end the user on a generic message with no retry, all because a
      // re-read of a row they can already see failed. Last known-good row
      // wins; the error is logged rather than rendered so a persistently
      // failing watch is still diagnosable.
      if (asyncValue.hasError) _logError();
      return dataBuilder(context, subject);
    }
    return _wrap(context, _surface(context));
  }

  void _logError() => debugPrint(
        'AsyncSubject error: ${asyncValue.error}\n${asyncValue.stackTrace}',
      );

  Widget _wrap(BuildContext context, Widget surface) =>
      surfaceWrapper?.call(context, surface) ?? surface;

  Widget _surface(BuildContext context) {
    // Error before absence: an `AsyncError` carrying a previous null is an
    // error, not a confirmed absence. Only a clean `AsyncData(null)` means the
    // row is genuinely gone.
    if (asyncValue.hasError) {
      _logError();
      return const ErrorSurface();
    }

    if (asyncValue.hasValue) {
      return missingBuilder != null
          ? missingBuilder!(context)
          : EmptySurface(
              icon: missingIcon,
              title: missingTitle,
              subtitle: missingSubtitle,
              cta: missingCta,
            );
    }

    return const LoadingSurface();
  }
}
