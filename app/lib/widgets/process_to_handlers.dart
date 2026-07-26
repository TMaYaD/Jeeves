/// Single canonical "process to" action bar for a Todo.
///
/// Replaces the four near-parallel button strips that used to live inline in
/// [ClarifyCard], the planning ritual's task-review card, and three
/// periodic-review steps (Waiting For, Projects, Someday/Maybe). Owns its
/// writes, delegated to [ClarificationService]; callsites configure
/// presentation only and never see [RoutingKind].
///
/// API surface lives on [ProcessAction]. Callsites that already hold a
/// [RoutingKind] (e.g. from a session record) translate via the co-located
/// [RoutingKindToProcessAction] extension.
library;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/action_draft.dart';
import '../models/todo.dart' show RoutingKind;
import '../providers/auth_provider.dart';
import '../services/clarification_service.dart';
import 'app_title_bar/app_title_bar.dart';
import 'capture/capture_action.dart';
import 'clarify_card.dart';
import 'next_action_dialog.dart';
import 'person_tag_picker.dart';

export '../models/todo.dart' show RoutingKind;

/// User-visible "process to" actions.
///
/// Five real routes (`next`, `waitingFor`, `someday`, `done`, `trash`) commit a
/// verdict against the [ClarifySubject] — in place for an Outcome, or as
/// create-link-stamp for a Capture. `trash` on a Capture is the one asymmetric
/// case: it is a zero-Outcome discard ([ClarificationService.discardCapture]),
/// not a created-then-trashed Outcome — and it labels itself "Discard Capture"
/// rather than "Trash" to say so. `completeCapture` is the Capture-only
/// terminal verdict of the n-m surface: it stamps `clarified_at` and creates
/// nothing, because the Outcomes were already carved by the New Outcome form,
/// so there is no destination left to pick. It is the green counterpart to
/// `trash`'s red "Discard Capture", and the two are mutually exclusive —
/// exactly one of them ends a Capture's clarify act.
/// `keep` stamps `last_clarified_at` on an
/// Outcome and leaves a Capture in the Inbox;
/// `nextActionDialog` is a modifier on the `next` button (not a standalone
/// button) — it is on by default, so tapping Next opens [NextActionDialog]
/// before invoking the `next` mapping unless a callsite removes it via
/// [ProcessToHandlers.except]; `reclarify` is a non-routing entry that opens
/// the [ClarifyCard] sub-flow as a full-page route, distinct from
/// `nextActionDialog` because it renders its own button rather than modifying
/// an existing one.
enum ProcessAction {
  keep,
  next,
  waitingFor,
  someday,
  done,
  trash,
  completeCapture,
  nextActionDialog,
  reclarify,
}

/// Whether an action reported through [ProcessToHandlers.onAfterRoute] means a
/// **Capture** reached a verdict — the decision that ends its clarify act and
/// spends anything a surface was holding on its behalf (ADR-0023).
///
/// Read by [ClarifyCard] to decide whether the retained draft may be dropped.
/// `onAfterRoute` fires for every action the bar handles, including ones that
/// deliberately leave the Capture in the Inbox, so "the hook ran" is not the
/// same question as "the Capture is done with".
///
/// Where each answer comes from, in this file:
///
/// - `next`, `waitingFor`, `someday`, `done`, `trash` all reach [_commit]
///   unconditionally once the subject still exists, and its [CaptureSubject]
///   branch either mints an Outcome and stamps `clarified_at` or discards the
///   Capture outright. Verdicts. (`done` is excepted on a Capture card, but it
///   is a verdict wherever it is offered.)
/// - `completeCapture` stamps `clarified_at` and creates nothing. A verdict.
/// - `keep` is an explicit no-op on a [CaptureSubject] in [_keep] — "leave it
///   in the Inbox", `clarified_at` stays NULL. **Not** a verdict.
/// - `reclarify` throws on a [CaptureSubject]; it can never report one.
/// - `nextActionDialog` notifies even when the dialog came back blank and no
///   write was made ([_nextWithDialog]), so it cannot promise a verdict.
///
/// Deliberately conservative on the last two: a false negative leaks a store
/// entry that a ceremony reset collects, while a false positive throws away
/// what the user typed. Only one of those is a bug ADR-0023 exists to prevent.
///
/// Says nothing about the n-m carve, where the same destinations leave the
/// Capture in the Inbox ([CaptureSubject.completesClarification]): that surface
/// reports through `CaptureOutcomesSection` rather than the clarify card's own
/// bar, and the card is given only its two genuine verdicts.
extension ProcessActionEndsCaptureClarification on ProcessAction {
  bool get endsCaptureClarification => switch (this) {
        ProcessAction.next ||
        ProcessAction.waitingFor ||
        ProcessAction.someday ||
        ProcessAction.done ||
        ProcessAction.trash ||
        ProcessAction.completeCapture =>
          true,
        ProcessAction.keep ||
        ProcessAction.reclarify ||
        ProcessAction.nextActionDialog =>
          false,
      };
}

/// Co-located translation: callsites holding a [RoutingKind] from a session
/// record convert at the read site so the widget never sees [RoutingKind].
extension RoutingKindToProcessAction on RoutingKind {
  ProcessAction toProcessAction() => switch (this) {
        RoutingKind.nextAction => ProcessAction.next,
        RoutingKind.waitingFor => ProcessAction.waitingFor,
        RoutingKind.maybe => ProcessAction.someday,
        RoutingKind.done => ProcessAction.done,
        RoutingKind.trash => ProcessAction.trash,
      };
}

/// Inverse of [RoutingKindToProcessAction]. Callsites that need to persist a
/// routed [ProcessAction] as a [RoutingKind] (e.g. wizard step records) use
/// this to translate at the write site. [ProcessAction.keep] and
/// [ProcessAction.reclarify] have no [RoutingKind] equivalent and return
/// null (`reclarify` opens a sub-flow rather than committing a routing —
/// the inner card's own [ProcessToHandlers] performs any routing it
/// produces and the sub-flow result bubbles back as the routed action).
/// [ProcessAction.nextActionDialog] collapses onto [RoutingKind.nextAction]
/// (it's a UI modifier, not a distinct route). [ProcessAction.completeCapture]
/// also returns null: the n-m verdict picks no destination at all — the
/// Outcomes it leaves behind carry their own, already applied.
extension ProcessActionToRoutingKind on ProcessAction {
  RoutingKind? toRoutingKind() => switch (this) {
        ProcessAction.next ||
        ProcessAction.nextActionDialog =>
          RoutingKind.nextAction,
        ProcessAction.waitingFor => RoutingKind.waitingFor,
        ProcessAction.someday => RoutingKind.maybe,
        ProcessAction.done => RoutingKind.done,
        ProcessAction.trash => RoutingKind.trash,
        ProcessAction.keep ||
        ProcessAction.reclarify ||
        ProcessAction.completeCapture =>
          null,
      };
}

/// What a clarify card has collected for a Capture, across both grains.
///
/// A Capture carries only title and notes; due date and tags are *Outcome*
/// attributes with no column to live in until the Outcome exists (ADR-0006),
/// and the card holds them here so
/// [ClarificationService.clarifyCaptureToOutcome] can write them onto the
/// Outcome it mints, in the same transaction as the provenance link and the
/// stamp.
///
/// [action] is the other grain: the phrase plus the effort attributes that
/// belong to the *action of doing* (ADR-0001, issue #477). Its nullness is the
/// single answer to "is there an Action here at all?" — the card nulls the
/// whole draft on a blank title rather than carrying a blank phrase beside
/// live effort values.
class ClarifyDraft {
  const ClarifyDraft({
    required this.title,
    this.notes,
    this.dueDate,
    this.tagIds = const <String>{},
    this.action,
  });

  /// The one assembly rule every clarify surface applies to its own field
  /// state, extracted so it is provable without pumping a widget.
  ///
  /// Three policies live here and nowhere else:
  ///
  /// - **Blank title nulls the whole [action].** A blank phrase beside live
  ///   effort values would claim an Action exists when none does.
  /// - **Person tags never travel.** Delegation is the orthogonal axis and the
  ///   Waiting For picker is the only thing that writes it, so a person *hint*
  ///   on the Capture is dropped rather than seeded onto the Outcome.
  /// - **[dueDate] is truncated to a calendar day.** The picker collects a
  ///   day; carrying its time component would make "due today" depend on the
  ///   moment the picker happened to open.
  ///
  /// [hintTags] are the Capture's tag hints — the source of both the person
  /// exclusion set and, when [draftTagIds] is null, the tags themselves.
  /// [draftTagIds] is the synchronously maintained draft a surface with
  /// editable pickers keeps (the DAO writes those pickers fire are
  /// `unawaited`, so the hint stream is a frame behind a user who taps a
  /// destination immediately after touching a tag). A surface that renders no
  /// pickers has no such draft and passes null.
  static ClarifyDraft assemble({
    required String title,
    required String notes,
    required DateTime? dueDate,
    required List<Tag> hintTags,
    required Set<String>? draftTagIds,
    required String? energyLevel,
    required int? timeEstimateMinutes,
  }) {
    final trimmedTitle = title.trim();
    final trimmedNotes = notes.trim();
    final personHintIds = {
      for (final t in hintTags)
        if (t.type == 'person') t.id,
    };
    return ClarifyDraft(
      title: trimmedTitle,
      notes: trimmedNotes.isEmpty ? null : trimmedNotes,
      dueDate: dueDate != null
          ? DateTime(dueDate.year, dueDate.month, dueDate.day)
          : null,
      tagIds: {
        for (final id in draftTagIds ?? {for (final t in hintTags) t.id})
          if (!personHintIds.contains(id)) id,
      },
      // Title-as-action coupling: a Capture is by definition a first
      // clarification, so there is no deliberate phrase to clobber and the
      // title always mirrors. applyRouting consumes the phrase only for Next
      // and Waiting For, so the other destinations are unaffected — but the
      // effort values travel to the Outcome columns either way (D3).
      action: trimmedTitle.isEmpty
          ? null
          : ActionDraft(
              text: trimmedTitle,
              energyLevel: energyLevel,
              timeEstimateMinutes: timeEstimateMinutes,
            ),
    );
  }

  final String title;
  final String? notes;
  final DateTime? dueDate;

  /// Non-person tags (context / project) to attach to the new Outcome. Person
  /// tags travel separately — the Waiting For picker supplies them.
  final Set<String> tagIds;

  /// The Action the card describes, or null when it describes none.
  ///
  /// The clarify card owns the policy that fills it (the title-as-action
  /// mirror, so a freshly clarified row never lands on the Next list
  /// actionless); the [ProcessAction.nextActionDialog] modifier overrides its
  /// phrase when active. Energy and estimate ride along and, on an Actionless
  /// destination, land on the Outcome columns as draft (D3).
  final ActionDraft? action;
}

/// What a [ProcessToHandlers] bar is clarifying — the two shapes of ADR-0006.
///
/// The distinction is not cosmetic: it selects an entirely different write.
/// Re-clarifying an [OutcomeSubject] edits one `todos` row in place, while
/// clarifying a [CaptureSubject] *creates* an Outcome, links it back to the
/// Capture (`capture_outcomes` provenance) and stamps `captures.clarified_at`.
sealed class ClarifySubject {
  const ClarifySubject();

  /// Row id of the subject — an Outcome id or a Capture id.
  String get id;

  /// Current title, for dialog copy and (on a Capture) the new Outcome.
  String get title;

  /// Text of the subject's current Action, if any. Always null for a Capture:
  /// no Outcome exists yet to carry one.
  String? get currentActionText;
}

/// An existing Outcome being re-clarified — the review surfaces.
///
/// [currentActionText] is supplied by the callsite rather than derived from
/// [todo]: the current Action is an entity in `actions`, not a column on the
/// Outcome (ADR-0001 story 3), and each surface already has it in the snapshot
/// it loaded. Pass null when the Outcome is Actionless (or when the callsite
/// genuinely has nothing to prefill).
final class OutcomeSubject extends ClarifySubject {
  const OutcomeSubject(this.todo, {this.currentActionText});

  final Todo todo;

  @override
  String get id => todo.id;

  @override
  String get title => todo.title;

  @override
  final String? currentActionText;
}

/// An Inbox Capture being clarified for the first time.
///
/// [draft] is a callback, not a value: the clarify card's title and notes live
/// in [TextEditingController]s that do not rebuild the widget on every
/// keystroke, so a draft snapshotted at build time would be stale by the time
/// the user taps a destination. It is read at tap time instead.
final class CaptureSubject extends ClarifySubject {
  const CaptureSubject({
    required this.capture,
    required this.draft,
    this.completesClarification = true,
  });

  final Capture capture;
  final ClarifyDraft Function() draft;

  /// Whether routing this Capture *ends* its clarify act.
  ///
  /// The one parameter separating the two clarify modes (CONTEXT.md § GTD
  /// Core). In 1-1 mode it is true: the first destination creates the Outcome,
  /// links it and stamps `clarified_at` in one shot, so routing is the
  /// clarification. In n-m mode it is false: routing carves *one* Outcome out
  /// of a Capture that may yield several, leaving the Capture in the Inbox
  /// until the user's own verdict ([ProcessAction.completeCapture] or
  /// [ProcessAction.trash]) ends it.
  ///
  /// A flag rather than a second subject type on purpose: both modes route the
  /// same draft to the same destinations through this one widget, and only the
  /// stamp differs.
  final bool completesClarification;

  @override
  String get id => capture.id;

  @override
  String get title => draft().title;

  @override
  String? get currentActionText => null;
}

/// Default actions (and modifiers) active when neither
/// [ProcessToHandlers.include] nor [ProcessToHandlers.except] override the
/// set. `nextActionDialog` is in here as a default-on modifier: promoting to
/// Next always captures a phrase unless a callsite opts out via `except`.
const _kDefaultActions = <ProcessAction>{
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.trash,
  ProcessAction.nextActionDialog,
};

/// Button-rendering order for the action bar. Modifier-only actions
/// (`nextActionDialog`) don't render their own button. `reclarify` sits
/// next to `keep` because both are "soft" non-routing entries — `keep`
/// stays put, `reclarify` opens the sub-flow.
const _kRenderOrder = <ProcessAction>[
  ProcessAction.keep,
  ProcessAction.reclarify,
  ProcessAction.next,
  ProcessAction.waitingFor,
  ProcessAction.someday,
  ProcessAction.done,
  ProcessAction.completeCapture,
  ProcessAction.trash,
];

/// Default user-visible labels for each renderable action, on an
/// [OutcomeSubject]. [_kCaptureLabels] overrides the ones that read
/// differently on a Capture.
const _kDefaultLabels = <ProcessAction, String>{
  ProcessAction.keep: 'Keep',
  ProcessAction.reclarify: 'Re-clarify…',
  ProcessAction.next: 'Next Action',
  ProcessAction.waitingFor: 'Waiting For',
  ProcessAction.someday: 'Someday',
  ProcessAction.done: 'Done',
  ProcessAction.trash: 'Trash',
  ProcessAction.completeCapture: 'Done with this Capture',
};

/// Capture-side label overrides, applied over [_kDefaultLabels] when the
/// subject is a [CaptureSubject].
///
/// `trash` is the one action whose canonical name depends on the subject.
/// On an Outcome it sets `Intent = trash`, landing the row on the **Trash**
/// List (CONTEXT.md). On a Capture it is the zero-Outcome **Discard**
/// verdict ([ClarificationService.discardCapture]): nothing is created, so
/// nothing ever reaches that List and "Trash" would name a destination the
/// item never arrives at.
const _kCaptureLabels = <ProcessAction, String>{
  ProcessAction.trash: 'Discard Capture',
};

/// Shown when a routing write throws. One message for every surface: the bar
/// owns the tap handler, so this is the only place a callsite could learn the
/// write failed.
const _kWriteFailedMessage = 'Operation failed. Please try again.';

/// Shown when the routing write landed but the callsite's [onAfterRoute] hook
/// threw. Deliberately distinct from [_kWriteFailedMessage]: "please try
/// again" would be wrong advice — the route is already committed.
const _kAfterRouteFailedMessage =
    'Saved, but finishing up failed. Some details may not have been updated.';

const _kDefaultIcons = <ProcessAction, IconData>{
  // `keep` is intentionally distinct from `next` so it doesn't collide
  // visually with the filled `Icons.check_circle` overlay drawn on the
  // `isPreviouslySelected` button — and so a future callsite surfacing
  // both (Keep + Next) reads unambiguously.
  ProcessAction.keep: Icons.bookmark_outline,
  ProcessAction.reclarify: Icons.tune,
  ProcessAction.next: Icons.check_circle_outline,
  ProcessAction.waitingFor: Icons.person_outlined,
  ProcessAction.someday: Icons.star_border,
  ProcessAction.done: Icons.task_alt_outlined,
  ProcessAction.trash: Icons.delete_outline,
  ProcessAction.completeCapture: Icons.task_alt_outlined,
};

const _kDefaultColors = <ProcessAction, Color>{
  ProcessAction.keep: Color(0xFF2563EB),
  ProcessAction.reclarify: Color(0xFF6B7280),
  ProcessAction.next: Color(0xFF2563EB),
  ProcessAction.waitingFor: Color(0xFF7C3AED),
  ProcessAction.someday: Color(0xFF6B7280),
  ProcessAction.done: Color(0xFF16A34A),
  ProcessAction.trash: Color(0xFFDC2626),
  // Deliberately the same green as `done`: the verdict occupies the slot Done
  // vacates and means the same thing at Capture scope — this is finished.
  ProcessAction.completeCapture: Color(0xFF16A34A),
};

class ProcessToHandlers extends ConsumerStatefulWidget {
  const ProcessToHandlers({
    super.key,
    required this.subject,
    this.include = const <ProcessAction>{},
    this.except = const <ProcessAction>{},
    this.disabled = const <ProcessAction>{},
    this.labels = const <ProcessAction, String>{},
    this.lastAction,
    this.onAfterRoute,
    this.onProcessingChanged,
  });

  /// The Capture or Outcome this bar clarifies — selects the write path.
  final ClarifySubject subject;

  /// Surfaces non-default actions (e.g. `keep`). The `nextActionDialog`
  /// modifier is on by default — remove it via [except], don't add it here.
  final Set<ProcessAction> include;

  /// Hides default actions, including the default-on `nextActionDialog`
  /// modifier — add `nextActionDialog` here to make Next route immediately
  /// without opening [NextActionDialog].
  final Set<ProcessAction> except;

  /// Renders these actions but disables their tap. Parent-owned validation
  /// (e.g. inbox card disables routes while title is empty).
  final Set<ProcessAction> disabled;

  /// Per-callsite label overrides keyed by [ProcessAction].
  ///
  /// **Use sparingly.** The default labels are the canonical vocabulary; the
  /// whole point of this widget is to collapse the pre-extraction drift
  /// ("Done (discard)"/"Trash", "Maybe"/"Send to Someday"/"Move to Maybe",
  /// "Promote to Next Action(s)"/"Next") into one set of names. Note that
  /// "Discard" is *not* drift: it is the canonical Capture-side name for
  /// `trash`, resolved automatically from the subject (see
  /// [_kCaptureLabels]). An override
  /// is only justified when the surface needs context the canonical label
  /// can't carry — e.g. `keep` becoming "Keep waiting" / "Keep on Someday" /
  /// "Still relevant" because plain "Keep" is ambiguous, or `next` becoming
  /// "Update next action…" to signal that [ProcessAction.nextActionDialog]
  /// is included and the button opens a dialog.
  ///
  /// Verb-prefixed synonyms of a canonical destination ("Promote to Next",
  /// "Send to Someday", "Mark done") are drift, not context — drop them.
  final Map<ProcessAction, String> labels;

  /// The action most recently applied to this item — drives the
  /// "previously selected" affordance on the matching button.
  final ProcessAction? lastAction;

  /// Called once after a successful write (or after `keep` stamps
  /// `last_clarified_at`). Not called when the user cancels a sub-dialog.
  ///
  /// Callsites that want to couple a route to an Action write (e.g.
  /// inbox-clarify treating the title as the next action) own that write
  /// here — the routing call itself is intent-only for plain
  /// `next` / `waitingFor`, and only the [ProcessAction.nextActionDialog]
  /// modifier writes an Action from inside the widget.
  final Future<void> Function(ProcessAction)? onAfterRoute;

  /// Notified with `true` when a tap begins its write and `false` once it
  /// settles — the same in-flight state that disables this bar's own buttons.
  ///
  /// For callsites that render their own affordances *beside* the bar and must
  /// disable them in step. The standalone clarify screen's Skip button is the
  /// motivating case: it navigates away, so leaving it live during a write lets
  /// the user pop the screen mid-flight and lose the post-write text flush.
  ///
  /// The closing `false` fires even when this bar has since unmounted — a
  /// parent that outlives it (conditional rendering, or an [onAfterRoute] that
  /// navigates) would otherwise stay latched on. **Callsites must therefore
  /// guard their own `setState` with a `mounted` check.**
  final ValueChanged<bool>? onProcessingChanged;

  @override
  ConsumerState<ProcessToHandlers> createState() => _ProcessToHandlersState();
}

class _ProcessToHandlersState extends ConsumerState<ProcessToHandlers> {
  bool _processing = false;

  /// Cached result of [_computeResolvedActions]: the default actions plus
  /// [ProcessToHandlers.include], minus [ProcessToHandlers.except]. Recomputed
  /// only when `include` / `except` change (see [didUpdateWidget]) so build
  /// doesn't reallocate the set on every frame.
  late Set<ProcessAction> _resolvedActions;

  @override
  void initState() {
    super.initState();
    _resolvedActions = _computeResolvedActions();
  }

  @override
  void didUpdateWidget(ProcessToHandlers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!setEquals(oldWidget.include, widget.include) ||
        !setEquals(oldWidget.except, widget.except)) {
      _resolvedActions = _computeResolvedActions();
    }
  }

  /// The default actions plus [ProcessToHandlers.include], minus
  /// [ProcessToHandlers.except]. Includes `nextActionDialog` when active.
  Set<ProcessAction> _computeResolvedActions() => <ProcessAction>{
        ..._kDefaultActions,
        ...widget.include,
      }..removeAll(widget.except);

  /// Renderable buttons: the resolved set minus modifier-only actions.
  /// `nextActionDialog` never renders its own button. Returns a fresh copy so
  /// the cached [_resolvedActions] set is never mutated.
  Set<ProcessAction> _renderableActions() =>
      Set<ProcessAction>.of(_resolvedActions)
        ..remove(ProcessAction.nextActionDialog);

  /// Whether the `nextActionDialog` modifier is active for this callsite —
  /// on by default, removed via [ProcessToHandlers.except]. When active,
  /// tapping Next opens [NextActionDialog] before routing.
  bool _dialogModifierActive() =>
      _resolvedActions.contains(ProcessAction.nextActionDialog);

  Future<void> _runOnce(Future<void> Function() action) async {
    if (_processing) return;
    setState(() => _processing = true);
    widget.onProcessingChanged?.call(true);
    try {
      await action();
    } catch (_) {
      // This widget owns the tap handler, so no callsite can wrap the write in
      // its own try/catch — an uncaught failure here escapes as an unhandled
      // async error and the tap silently does nothing. Report it instead.
      // [onAfterRoute] is deliberately not reached: the write did not land, so
      // advancing a cursor or recording a routing would be a lie.
      //
      // Only *write* failures reach here: [_notifyAfterRoute] handles the
      // callback separately, so this message never claims a landed write
      // failed.
      _report(_kWriteFailedMessage);
    } finally {
      if (mounted) setState(() => _processing = false);
      widget.onProcessingChanged?.call(false);
    }
  }

  /// Invokes the callsite's [ProcessToHandlers.onAfterRoute] hook behind its
  /// own error boundary.
  ///
  /// The routing write has already landed by the time this runs, so a failing
  /// hook must not surface as [_kWriteFailedMessage]: that would invite the
  /// user to retry a write that actually succeeded. The hook's own failure is
  /// still reported — swallowing it silently is what left callsite bookkeeping
  /// (cursor advance, text flush) failing invisibly.
  Future<void> _notifyAfterRoute(ProcessAction action) async {
    try {
      await widget.onAfterRoute?.call(action);
    } catch (_) {
      _report(_kAfterRouteFailedMessage);
    }
  }

  void _report(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// The canonical label for [a] against the current subject — the
  /// [_kCaptureLabels] override on a Capture, else [_kDefaultLabels].
  String _labelFor(ProcessAction a) =>
      (widget.subject is CaptureSubject ? _kCaptureLabels[a] : null) ??
      _kDefaultLabels[a]!;

  Future<void> _onTap(ProcessAction action) async {
    switch (action) {
      case ProcessAction.keep:
        await _runOnce(_keep);
      case ProcessAction.reclarify:
        await _runOnce(_reclarify);
      case ProcessAction.next:
        if (_dialogModifierActive()) {
          await _runOnce(_nextWithDialog);
        } else {
          await _runOnce(_next);
        }
      case ProcessAction.waitingFor:
        await _runOnce(_waitingFor);
      case ProcessAction.someday:
        await _runOnce(() => _route(ProcessAction.someday));
      case ProcessAction.done:
        await _runOnce(() => _route(ProcessAction.done));
      case ProcessAction.trash:
        await _runOnce(() => _route(ProcessAction.trash));
      case ProcessAction.completeCapture:
        await _runOnce(_completeCapture);
      case ProcessAction.nextActionDialog:
        // Modifier — never rendered as a standalone button. Defensive no-op.
        return;
    }
  }

  ClarificationService get _clarification =>
      ref.read(clarificationServiceProvider);

  /// Snapshot-based callsites (inbox-clarify, periodic review) can lose a
  /// row between render and tap — sync or another device may hard-delete it.
  /// PowerSync exposes `todos` and `captures` as SQLite VIEWs with INSTEAD OF
  /// triggers, so the affected-rows count for an UPDATE is always 0; we can't
  /// tell from the write whether anything happened. Pre-check existence here
  /// so we don't fire [onAfterRoute] (which advances the snapshot cursor and
  /// records a phantom routing record) for a row that no longer exists.
  Future<bool> _subjectExists() => switch (widget.subject) {
        OutcomeSubject(:final todo) => _clarification.exists(todo.id),
        CaptureSubject(:final capture) =>
          _clarification.captureExists(capture.id),
      };

  /// Commits the routing verdict [to] against the subject.
  ///
  /// For an [OutcomeSubject] this edits the existing `todos` row in place.
  /// For a [CaptureSubject] it creates the Outcome the draft describes, links
  /// it back to the Capture as provenance and stamps `clarified_at` — except
  /// for Trash, which is the zero-Outcome discard: it stamps and creates
  /// nothing (ADR-0006).
  Future<void> _commit(
    RoutingKind to, {
    String? actionText,
    Set<String>? personTagIds,
  }) async {
    switch (widget.subject) {
      case OutcomeSubject(:final todo):
        await _clarification.clarifyToOutcome(
          todo.id,
          to: to,
          actionText: actionText,
          personTagIds: personTagIds,
          userId: personTagIds != null ? ref.read(currentUserIdProvider) : null,
        );
      case CaptureSubject(:final capture, :final draft):
        if (to == RoutingKind.trash) {
          await _clarification.discardCapture(capture.id);
          return;
        }
        final d = draft();
        if (!(widget.subject as CaptureSubject).completesClarification) {
          // n-m: carve one Outcome out of the Capture and leave the Capture in
          // the Inbox. Same draft, same destination — only the stamp differs
          // (see [CaptureSubject.completesClarification]).
          await _clarification.carveOutcome(
            capture.id,
            userId: ref.read(currentUserIdProvider),
            title: d.title,
            to: to,
            notes: d.notes,
            dueDate: d.dueDate,
            action: _mergedAction(d, actionText),
            personTagIds: personTagIds,
            tagIds: d.tagIds,
          );
          return;
        }
        await _clarification.clarifyCaptureToOutcome(
          capture.id,
          to: to,
          userId: ref.read(currentUserIdProvider),
          title: d.title,
          notes: d.notes,
          dueDate: d.dueDate,
          action: _mergedAction(d, actionText),
          personTagIds: personTagIds,
          tagIds: d.tagIds,
        );
    }
  }

  /// The Action to write, reconciling the card's draft with a phrase the
  /// [ProcessAction.nextActionDialog] modifier collected.
  ///
  /// The dialog's phrase wins over the card's title mirror, but only the
  /// *phrase*: the effort attributes the card collected ride through, which a
  /// bare `actionText ?? d.action?.text` would drop.
  ActionDraft? _mergedAction(ClarifyDraft d, String? actionText) {
    if (actionText == null || actionText.isEmpty) return d.action;
    return d.action?.copyWith(text: actionText) ??
        ActionDraft(text: actionText);
  }

  Future<void> _keep() async {
    if (!await _subjectExists()) return;
    switch (widget.subject) {
      case OutcomeSubject(:final todo):
        await _clarification.stampClarified(todo.id);
      case CaptureSubject():
        // "Keep" on a Capture means leave it in the Inbox: the clarify act is
        // not complete, so `clarified_at` must stay NULL. Stamping here would
        // clear the item from the Inbox without producing either an Outcome or
        // a discard verdict — the one outcome the split exists to prevent.
        break;
    }
    await _notifyAfterRoute(ProcessAction.keep);
  }

  /// Opens the [ClarifyCard] sub-flow as a full-page route. The pushed
  /// card owns its own [ProcessToHandlers], so any routing performed
  /// inside is committed by that inner widget — this outer call only
  /// bubbles the chosen action through [onAfterRoute] for callsite
  /// bookkeeping (record routing, advance cursor). Backing out without
  /// routing maps to [ProcessAction.keep] so the review step advances
  /// without recording a routing.
  Future<void> _reclarify() async {
    final subject = widget.subject;
    if (subject is! OutcomeSubject) {
      // Re-clarify is a review-surface entry: it re-opens a card on an Outcome
      // that was already clarified once. A Capture has never been clarified,
      // so there is nothing to re-open — its first pass through the card *is*
      // the clarification. No inbox callsite includes this action; reaching
      // here means a callsite was miswired, so fail loudly.
      throw UnsupportedError(
        'ProcessAction.reclarify applies to an Outcome, not a Capture',
      );
    }
    if (!await _subjectExists()) return;
    if (!mounted) return;
    final routed = await Navigator.of(context).push<ProcessAction>(
      MaterialPageRoute<ProcessAction>(
        builder: (_) => ReclarifyRoute(todoId: subject.todo.id),
      ),
    );
    if (!mounted) return;
    if (routed == null) {
      await _keep();
      return;
    }
    await _notifyAfterRoute(routed);
  }

  /// The n-m surface's completing verdict: stamp `clarified_at`, create
  /// nothing.
  ///
  /// Every Outcome this Capture yields was already carved and routed by the
  /// New Outcome form, so there is no draft left to mint and no destination to
  /// apply — which is why this is not a [RoutingKind] and reports no routing a
  /// ceremony could record.
  Future<void> _completeCapture() async {
    final subject = widget.subject;
    if (subject is! CaptureSubject) {
      // Only a Capture has a clarify act to complete; an Outcome's equivalent
      // is `done`, which is a routing. A callsite offering this on an Outcome
      // is miswired, so fail loudly rather than silently doing nothing.
      throw UnsupportedError(
        'ProcessAction.completeCapture applies to a Capture, not an Outcome',
      );
    }
    if (!await _subjectExists()) return;
    await _clarification.completeCaptureClarification(subject.capture.id);
    await _notifyAfterRoute(ProcessAction.completeCapture);
  }

  Future<void> _next() async {
    if (!await _subjectExists()) return;
    await _commit(RoutingKind.nextAction);
    await _notifyAfterRoute(ProcessAction.next);
  }

  Future<void> _nextWithDialog() async {
    // Edit-existing semantics: prefer the current Action's text so the user
    // sees what's currently saved. A Capture has none — its Outcome does not
    // exist yet — so the dialog opens empty.
    final initial = widget.subject.currentActionText ?? '';
    final result = await showNextActionDialog(
      context,
      initial: initial,
      taskTitle: widget.subject.title,
    );
    if (result == null) return; // user cancelled
    if (!mounted) return;
    if (!await _subjectExists()) return;
    if (result.isNotEmpty) {
      // A blank save must not route: promoting to Next with no phrase
      // would land the item actionless on the Next list — the exact
      // outcome the dialog modifier exists to prevent. Skip the write but
      // still notify the callsite so it can react (e.g. clear a stale
      // action record); its handler re-reads the row and sees the
      // unchanged value.
      await _commit(RoutingKind.nextAction, actionText: result);
    }
    await _notifyAfterRoute(ProcessAction.nextActionDialog);
  }

  Future<void> _waitingFor() async {
    // Pre-seed from the existing Outcome's delegates; a Capture has none —
    // its Outcome does not exist yet (ADR-0006).
    final assigned = switch (widget.subject) {
      OutcomeSubject(:final todo) => await _clarification.getPersonTagIds(
          todo.id,
        ),
      CaptureSubject() => const <String>{},
    };
    if (!mounted) return;

    // Selection-only on both branches: `_commit`'s routing write replaces the
    // person-tag set atomically (clarifyToOutcome) or attaches it to the
    // Outcome it mints (clarifyCaptureToOutcome), so the picker has nothing
    // left to write.
    final selected = await showPersonTagPicker(
      context,
      assignedPersonTagIds: assigned,
      requireSelection: true,
    );
    if (selected == null || !mounted) return; // user cancelled

    // Checked after the picker closes but before any write: confirming into a
    // row that has since vanished must leave nothing behind.
    if (!await _subjectExists()) return;

    // Routing to waitingFor is intent-only — the Action is on the orthogonal
    // "what's the action?" axis and is not touched here. Callsites that want
    // to couple a phrase write own it via `onAfterRoute` (or the
    // `nextActionDialog` modifier when editing an existing phrase).
    await _commit(RoutingKind.waitingFor, personTagIds: selected);
    await _notifyAfterRoute(ProcessAction.waitingFor);
  }

  Future<void> _route(ProcessAction action) async {
    if (!await _subjectExists()) return;
    final to = switch (action) {
      ProcessAction.someday => RoutingKind.maybe,
      ProcessAction.done => RoutingKind.done,
      ProcessAction.trash => RoutingKind.trash,
      _ => throw StateError('Unexpected route action: $action'),
    };
    // Person tags are orthogonal to intent: a delegated task can become
    // `someday` / `done` / `trash` without losing its delegate. The picker
    // is the only path that mutates person tags.
    await _commit(to);
    await _notifyAfterRoute(action);
  }

  @override
  Widget build(BuildContext context) {
    final renderable = _renderableActions();
    final ordered = _kRenderOrder.where(renderable.contains).toList();

    return AnimatedOpacity(
      opacity: _processing ? 0.4 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < ordered.length; i++) ...[
            _ActionButton(
              label: widget.labels[ordered[i]] ?? _labelFor(ordered[i]),
              icon: _kDefaultIcons[ordered[i]]!,
              color: _kDefaultColors[ordered[i]]!,
              enabled: !_processing && !widget.disabled.contains(ordered[i]),
              isPreviouslySelected: widget.lastAction == ordered[i] ||
                  // Tapping Next with the dialog modifier records
                  // `nextActionDialog` in callsite state; highlight Next.
                  (ordered[i] == ProcessAction.next &&
                      widget.lastAction == ProcessAction.nextActionDialog),
              onTap: () => _onTap(ordered[i]),
            ),
            if (i < ordered.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Outlined button used for each action. Mirrors the styling of the existing
/// `_ActionButton` in `_review_card.dart` so visual parity is preserved
/// across the migrated callsites.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.isPreviouslySelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final bool isPreviouslySelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = enabled ? color : color.withValues(alpha: 0.38);
    return OutlinedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18, color: iconColor),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (isPreviouslySelected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check_circle, size: 16, color: iconColor),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor:
            isPreviouslySelected ? color.withValues(alpha: 0.08) : null,
        side: BorderSide(
          color: color.withValues(
            alpha: !enabled
                ? 0.2
                : isPreviouslySelected
                    ? 0.85
                    : 0.4,
          ),
          width: isPreviouslySelected ? 1.5 : 1.0,
        ),
        alignment: Alignment.centerLeft,
        minimumSize: const Size.fromHeight(44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    );
  }
}

/// The third clarify host: a full-page route wrapping [ClarifyCard.forOutcome].
///
/// Named rather than inlined into `_ProcessToHandlersState._reclarify` so all
/// three clarify hosts read alike — a ceremony step, [InboxClarifyScreen] and
/// this — and so the chrome one of them owns is visible as chrome rather than
/// as a builder nested inside a navigation call.
///
/// It pops with the [ProcessAction] the inner card routed, or with null when
/// the user backs out without routing; the caller maps that to
/// [ProcessAction.keep] so a review step advances without recording a routing.
///
/// Deliberately thinner than [InboxClarifyScreen]: no `PopScope`, no
/// missing-state CTA. Backing out mid-write is not the same hazard here — the
/// subject already exists and the write edits it in place, so there is no
/// create-link-stamp sequence to interrupt — and the app bar's back arrow is a
/// way out the missing state can rely on. Neither guard was present in the
/// inline version this replaces, so neither absence is a regression; adding
/// them would be a change rather than a move.
class ReclarifyRoute extends StatelessWidget {
  const ReclarifyRoute({super.key, required this.todoId});

  /// The Outcome being re-clarified.
  final String todoId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTitleBar(
        title: 'Re-clarify',
        pinnedAction: captureAction(context),
      ),
      body: ClarifyCard.forOutcome(
        todoId: todoId,
        onAfterRoute: (action) async {
          // The card awaits its own post-route bookkeeping before calling
          // this, so the route can be gone by the time it runs — pop the
          // screen from underneath (platform back, a deep link) and
          // `Navigator.of` on a defunct element throws.
          if (!context.mounted) return;
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop(action);
          }
        },
      ),
    );
  }
}
