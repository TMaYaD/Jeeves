/// Builder that renders the standard loading / error / missing / data surfaces
/// for an [AsyncValue] holding a **single subject** — the one row a surface is
/// bound to, watched by id.
///
/// The single-row counterpart of [AsyncList], and the answer to one specific
/// bug: every subject-bound surface used to collapse `AsyncValue<T?>` into a
/// null check and render a spinner, so *loading*, *errored* and *gone* were
/// indistinguishable on screen.
///
/// **`AsyncData(null)` means the row is gone, not that it is still loading.**
/// The subject watches (`CaptureDao.watchCapture`, `TodoDao.watchTodo`) use
/// drift's `watchSingleOrNull()`, which emits `null` for zero rows and keeps
/// the stream open. The app has no soft-delete — Trash is an `intent` value, so
/// a trashed row still emits non-null — which leaves exactly one way for a
/// subject to become null: it was hard-deleted, typically by sync applying a
/// remote delete under an open screen. Collapsing the three states into
/// `value == null -> spinner` is the anti-pattern this widget exists to
/// prevent; a user whose item was deleted on another device would otherwise
/// stare at a spinner that never resolves.
///
/// Branch order: error → loading → missing → data.
///
/// Every missing state must offer a way out ([missingCta]) — a surface bound to
/// a row that no longer exists is a dead end otherwise. Error copy never leaks
/// the exception: the detail is logged, the user sees [ErrorSurface]'s fixed
/// text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state_surfaces.dart';

/// The "gone, not loading" test, in one place.
///
/// `AsyncData(null)` from a subject watch means the row was hard-deleted, not
/// that it is still arriving — the subject watches use `watchSingleOrNull()`,
/// which emits null for zero rows and keeps the stream open, and the app has no
/// soft-delete (Trash is an `intent` value, so a trashed row still emits
/// non-null). A reload retains its previous value, so `hasValue` alone is not
/// the test: it stays true across a refresh that began from a null.
///
/// [AsyncSubject] branches on this to pick the missing panel, and the surfaces
/// that write — `TaskDetailScreen`, `TaskStatusRow`, `ClarifyCard`,
/// `InboxClarifyScreen` — use it to refuse writes against a row that is gone.
/// Named once so those five callers cannot drift apart on what "gone" means.
extension AsyncSubjectGone<T> on AsyncValue<T?> {
  bool get isGone => hasValue && value == null;
}

/// Renders the four states of a subject-bound watch. See the library doc.
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
    this.chrome,
  });

  /// The watched subject. `null` inside [AsyncData] means *gone*.
  final AsyncValue<T?> asyncValue;

  /// Renders the surface once the subject is present. Never called with null.
  final Widget Function(BuildContext context, T subject) dataBuilder;

  /// Missing-state headline. Required: every surface owns its own copy
  /// (e.g. "This item is no longer in your Inbox").
  final String missingTitle;

  /// Optional icon above [missingTitle].
  final IconData? missingIcon;

  /// Optional secondary line below [missingTitle] — usually the *why*
  /// ("It may have been deleted on another device").
  final String? missingSubtitle;

  /// The way out of the missing state: a button that gets the user somewhere
  /// sensible (back to the Inbox, on to the next ceremony item). Omit only
  /// when the host already renders an escape outside this widget.
  final Widget? missingCta;

  /// Escape hatch for a host that wants something other than the standard
  /// missing panel — e.g. `ActiveFocusScreen`, which redirects rather than
  /// asking the user to acknowledge a task that vanished mid-sprint. Replaces
  /// the missing surface entirely (including [chrome]).
  final WidgetBuilder? missingBuilder;

  /// Wraps the loading / error / missing surfaces in the host's page chrome
  /// (app bar, background) so the three non-data states are not bare against
  /// a screen whose data state is a full [Scaffold].
  final Widget Function(BuildContext context, Widget surface)? chrome;

  @override
  Widget build(BuildContext context) {
    final async = asyncValue;

    // Error before loading, and deliberately not via `AsyncValue.when`.
    // Riverpod 3 auto-retries a failed provider, so a stream error does not
    // arrive as `AsyncError` — it arrives as `AsyncLoading` *carrying* an
    // error, and `when` dispatches that to its loading branch. Routing on
    // `isLoading` first would therefore turn every errored watch into another
    // indefinite spinner: the same defect as the null collapse, one state
    // over. A subject that already holds a row is exempt — showing the last
    // known row beats replacing it with an error panel mid-retry.
    //
    // That exemption is keyed on holding an actual row, not merely on
    // `hasValue`. A watch that emitted `null` and then errored retains the
    // null, so a bare `hasValue` test would skip this branch and render the
    // *missing* panel — telling the user the row was deleted when the read
    // merely failed, and offering an escape premised on that. A retained null
    // is nothing worth preserving, so it yields to the error.
    //
    // The log fires for *every* error, exempt or not: the exempt case keeps the
    // row on screen rather than an error panel, which is the right surface but
    // would otherwise swallow the exception entirely. [ErrorSurface]'s bargain
    // is that the detail reaches the log even when it never reaches the user.
    if (async.hasError) {
      debugPrint('AsyncSubject error: ${async.error}\n${async.stackTrace}');
      if (async.value == null) return _chromed(context, const ErrorSurface());
    }
    // Keyed on the same "is there a row worth showing" test as the error branch
    // rather than on `hasValue` alone. A reload that started from a retained
    // *null* still reports `hasValue`, so testing that flag would fall through
    // to the missing panel and assert the row is deleted while the read that
    // would say otherwise is still in flight. A reload holding a real row is
    // exempt, as before: the last known row beats a spinner mid-refresh.
    if (async.isLoading && async.value == null) {
      return _chromed(
        context,
        const Center(child: CircularProgressIndicator()),
      );
    }

    final subject = async.value;
    // `async.isGone` by construction: the error-with-null and loading-with-null
    // branches above have already returned, so a null here is a delivered null.
    // Written as a null check rather than the extension because that is what
    // promotes `subject` to non-null for [dataBuilder] — spelling it `isGone`
    // would buy consistency at the price of an unchecked cast.
    if (subject == null) {
      if (missingBuilder != null) return missingBuilder!(context);
      return _chromed(
        context,
        EmptySurface(
          icon: missingIcon,
          title: missingTitle,
          subtitle: missingSubtitle,
          cta: missingCta,
        ),
      );
    }
    return dataBuilder(context, subject);
  }

  Widget _chromed(BuildContext context, Widget surface) =>
      chrome != null ? chrome!(context, surface) : surface;
}
