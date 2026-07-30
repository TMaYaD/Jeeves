/// What "sync starts at enrolment" is, in code: one closure, two callers.
///
/// [SyncLifecycle.activate] is both the post-enrolment hook and the
/// on-activation resume, because the acceptance criteria demand both. An
/// interrupted initial upload must complete on the *next sync*, including after a
/// process death — and the member credential is memory-only by design
/// (`SyncStack`'s docstring: it is minted by a proof-of-possession exchange and
/// held in memory only), so "the next sync" on a relaunched device begins by
/// re-minting that credential. There is therefore no separate resume path to
/// keep in step with the enrolment path; there is one path, called twice.
///
/// A plain class, every dependency injected, so the closure the harness drives is
/// the closure production runs — the same discipline `SyncStack` and
/// `SignalListener` are built under. `providers/sync_lifecycle_provider.dart` is
/// the only production caller.
///
/// ## The order is load-bearing
///
/// 1. **Derive enrolment state from the store, no network.** `notEnrolled` or
///    `foundingIncomplete` and nothing happens beyond *settling capture silent*:
///    an un-enrolled device keeps working fully offline and authors nothing, and
///    a half-founded one must not walk or attach either — its log is not the log
///    its next ceremony will continue. The settle is a decision, not an absence
///    of one: the seam buffers from construction, so "author nothing" has to be
///    *said*, or its buffer grows for the session.
/// 2. **Bind capture, from the local reads alone.** From here new domain writes
///    author ops. Moved ahead of every network step on purpose: the seam buffers
///    each write made since construction, and binding drains that buffer, so the
///    decision must not wait on the proof-of-possession round trip below. The
///    preferences client `bind` takes is built locally — the member transport
///    propagates per factory call, so one built before the attach tolerates none
///    existing yet.
/// 3. **Re-attach the member transport if absent** (the relaunch case), by
///    proof-of-possession over the *stored* keys. Nothing is persisted: a
///    per-launch PoP is self-refreshing and leaves no credential at rest. This is
///    also the recovery from `SignalListenerState.authParked`. It sits inside the
///    same `try` as step 4, so an offline relaunch's failure to mint a credential
///    returns `syncFailed` — capture already bound, writes queuing — rather than
///    escaping unclassified and leaving the whole session silent.
/// 4. **Sync both Workspace clients.** Pull-before-authoring narrows to the
///    initial upload's diff skip: a device that *walked* before pulling would
///    re-author a store the log already holds. DAO ops authored between bind and
///    this pull are already reality, and correct — they queue and post. A failure
///    here stops the activation — the next one retries — and specifically leaves
///    the marker alone. The preferences client is re-fetched from the factory
///    *after* the attach, so it carries the member transport the pre-attach one
///    could not.
/// 5. **Initial upload, if the marker is unset.** On a completed pass the marker
///    is set with the report. A transport failure mid-walk propagates, the marker
///    stays unset, and the next activation resumes through the diff skip.
/// 6. **Start the signal listeners and the debounced outbox flusher.** Without
///    step 6 a DAO-authored op would sit in the outbox until the next cold start,
///    and "sync starts at enrolment" would name a one-shot upload rather than
///    sync. This is the minimal ongoing loop; app-lifecycle and connectivity
///    refinement can follow without changing the shape.
///
/// **Refusals do not hold the marker open.** An entity `capture()` refused (#573)
/// is a permanent data anomaly, not retryable transport state, so retrying it for
/// ever would mean never setting the marker on a store that contains one. It is
/// counted in the report the marker row carries.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/gtd_database.dart';
import 'domain_op_capture.dart';
import 'enrolment_state.dart';
import 'ids.dart';
import 'initial_upload.dart';
import 'initial_upload_plan.dart';
import 'reducer.dart';
import 'signal_listener.dart';
import 'sync_client.dart';
import 'sync_database.dart';
import 'sync_stack.dart';
import 'sync_transport.dart';

/// How long after an authored op the outbox is flushed.
///
/// Not configurable: it trades one round trip against a few seconds of latency
/// on a queue that is already durable, and neither side of that trade is a
/// deployment concern. Long enough that a burst of DAO writes — a clarify pass
/// touching several entities — leaves as one POST rather than one per write;
/// short enough that a user who writes something and closes the app has it on
/// the server.
const Duration outboxFlushDebounce = Duration(seconds: 3);

/// The per-account initial-upload marker, over the sync store.
///
/// A row means "a pass completed for this account". Absence is the retry
/// condition, which is why nothing here writes a partial row.
class InitialUploadMarkerStore {
  InitialUploadMarkerStore(this._db);

  final SyncDatabase _db;

  Future<InitialUploadStateRow?> read(String userId) =>
      (_db.select(_db.initialUploadState)
            ..where((row) => row.userId.equals(userId)))
          .getSingleOrNull();

  Future<bool> isComplete(String userId) async => await read(userId) != null;

  /// Record a completed pass. Upsert rather than insert: a device that walks
  /// again — because the marker was cleared, or because a later slice asks it to
  /// — records the newer pass rather than throwing on its own history.
  Future<void> markComplete({
    required String userId,
    required int completedAtUtcMs,
    required InitialUploadReport report,
  }) =>
      _db.into(_db.initialUploadState).insertOnConflictUpdate(
            InitialUploadStateCompanion.insert(
              userId: userId,
              completedAtUtcMs: completedAtUtcMs,
              lastReportJson: Value(jsonEncode(report.toJson())),
            ),
          );
}

/// Where an activation got to. Returned so a caller — and a test — can assert
/// what happened without reading four stores to infer it.
enum SyncActivation {
  /// Step 1 said no: nothing was attached, bound, synced or authored.
  notEnrolled,

  /// Step 1 said the ceremony is unfinished. Same non-effect, different cause.
  foundingIncomplete,

  /// The member transport could not be attached (step 3) or the first sync
  /// failed (step 4) — offline launch, most likely. Capture is *already* bound,
  /// so an offline device queues its writes correctly; the marker is untouched,
  /// and nothing is listening. This is what turns an offline enrolled relaunch
  /// into correct queue-and-retry instead of a full-session silent drop.
  syncFailed,

  /// Step 5 did not finish, so the marker is **unset** and the next activation
  /// resumes through the diff skip. The listeners still start: they are what
  /// makes the retry happen, and a device left un-subscribed because its upload
  /// failed would retry only at the next cold start.
  ///
  /// The failure is not swallowed — the absent marker is the durable evidence,
  /// and this value is how a caller learns of it without reading the store.
  uploadIncomplete,

  /// A [SyncLifecycle.deactivate] landed while the sequence was mid-await — a
  /// sign-out during the proof-of-possession round trip, most likely. Everything
  /// after that point is abandoned: nothing is bound, uploaded or subscribed for
  /// an account nobody is signed into any more.
  deactivated,

  /// The whole sequence ran. Says nothing about whether the upload authored
  /// anything: a completed marker means it had nothing to do.
  active,
}

class SyncLifecycle {
  SyncLifecycle({
    required SyncStack stack,
    required GtdDatabase domain,
    required WorkspaceRoutingOpCapture capture,
    SyncTransport? signalTransport,
    Timer Function(Duration, void Function())? timerFactory,
    Future<void> Function(Duration)? listenerDelay,
    Duration flushDebounce = outboxFlushDebounce,
    String Function() mintTagId = initialUploadRandomTagId,
  })  : _stack = stack,
        _domain = domain,
        _capture = capture,
        _signalTransport = signalTransport,
        _timerFactory = timerFactory ?? Timer.new,
        _listenerDelay = listenerDelay,
        _flushDebounce = flushDebounce,
        _mintTagId = mintTagId,
        _markers = InitialUploadMarkerStore(stack.database),
        _registry = CollectionRegistry(stack.database);

  final SyncStack _stack;
  final GtdDatabase _domain;
  final WorkspaceRoutingOpCapture _capture;

  /// The transport the signal sockets are opened over. Null means "the member
  /// transport this device minted", which is what production wants; the harness
  /// hands in its own link so faults are injectable.
  final SyncTransport? _signalTransport;

  final Timer Function(Duration, void Function()) _timerFactory;
  final Future<void> Function(Duration)? _listenerDelay;
  final Duration _flushDebounce;
  final String Function() _mintTagId;
  final InitialUploadMarkerStore _markers;
  final CollectionRegistry _registry;

  final List<SignalListener> _listeners = <SignalListener>[];
  Timer? _pendingFlush;

  /// Single-flight. Two activations can be asked for at once — the enrolment
  /// outcome and the eager provider watch are independent callers — and the
  /// second one has nothing to add: it would re-derive the same state, re-bind
  /// the same clients and walk a store the first is already walking.
  Future<SyncActivation>? _inFlight;

  /// Bumped by [deactivate], and re-read after every await in [_activate].
  ///
  /// Single-flight collapses concurrent *activations*; it says nothing about a
  /// deactivation that lands mid-sequence, and `sync_lifecycle_provider.dart`
  /// starts an activation un-awaited and then disposes on the next sign-out — so
  /// an ordinary sign-out during step 2's network round trip would otherwise let
  /// the abandoned activation bind the process-wide capture seam to the previous
  /// account's clients and open sockets `deactivate` has already stopped tracking.
  int _generation = 0;

  final Completer<void> _firstSyncSettled = Completer<void>();

  /// Completes the first time step 4 succeeds — the spine's "the initial pull is
  /// in" signal, and what `postSyncHooksProvider` arms its one-shot fixup on.
  Future<void> get firstSyncSettled => _firstSyncSettled.future;

  /// Run the sequence. Safe to call repeatedly: every step is idempotent, and
  /// concurrent calls collapse onto the one in flight.
  Future<SyncActivation> activate() {
    final running = _inFlight;
    if (running != null) return running;
    final started = _activate();
    _inFlight = started;
    return started.whenComplete(() => _inFlight = null);
  }

  Future<SyncActivation> _activate() async {
    final generation = _generation;
    bool deactivated() => generation != _generation;

    final status = await _stack.readEnrolmentStatus();
    switch (status.state) {
      case EnrolmentState.notEnrolled:
        _capture.unbind();
        return SyncActivation.notEnrolled;
      case EnrolmentState.foundingIncomplete:
        _capture.unbind();
        return SyncActivation.foundingIncomplete;
      case EnrolmentState.enrolled:
        break;
    }
    if (deactivated()) return SyncActivation.deactivated;

    // Bind capture before any network, from the local reads alone: the enrolment
    // decision is what disposes of the buffered ops, and it must not wait on the
    // proof-of-possession round trip below. `workspaceClientFactory` builds the
    // preferences client locally — the member transport propagates per-call, so
    // one built before the attach tolerates none existing yet. `onOpAuthored` is
    // armed *through* bind, before it drains, so a buffered op schedules the
    // debounced flush rather than sitting in the outbox until the next write.
    final gtdClient = _stack.defaultClient;
    await _capture.bind(
      gtdClient: gtdClient,
      preferencesClient: await _stack
          .workspaceClientFactory(userPreferencesWorkspaceId(_stack.userId)),
      onOpAuthored: _scheduleOutboxFlush,
    );
    if (deactivated()) return SyncActivation.deactivated;

    // The PoP is now inside the try: an offline enrolled relaunch throws here,
    // and that must classify as `syncFailed` (capture is already bound; writes
    // queue) rather than escape unclassified and leave the session silent.
    late final SyncClient preferencesClient;
    try {
      await _attachMemberTransportIfAbsent();
      // A sign-out that landed while the PoP was parked stops here rather than
      // syncing the old account's log. A bare `return` inside the try is not a
      // throw, so it bypasses the `syncFailed` catch. Capture is already settled
      // silent by `deactivate`'s `unbind`, so no re-bind is needed.
      if (deactivated()) return SyncActivation.deactivated;
      // Re-fetch after the attach: the client built for bind was constructed
      // before the member transport existed, so its own `sync()` would have no
      // transport. The factory memoises and propagates the credential per-call,
      // so this returns the same client now carrying it.
      preferencesClient = await _stack
          .workspaceClientFactory(userPreferencesWorkspaceId(_stack.userId));
      await gtdClient.sync();
      await preferencesClient.sync();
    } on Object {
      // Offline launch, most likely. Capture stays bound — writes queue — and
      // the marker stays untouched, so the next activation resumes.
      return SyncActivation.syncFailed;
    }
    if (deactivated()) return SyncActivation.deactivated;
    if (!_firstSyncSettled.isCompleted) _firstSyncSettled.complete();

    var uploaded = true;
    try {
      await _uploadIfMarkerUnset(
        gtdClient: gtdClient,
        preferencesClient: preferencesClient,
      );
    } on Object {
      // `runInitialUpload` propagates a transport failure on purpose — hiding it
      // would leave the user believing the server holds ops it has never seen —
      // and the marker stays unset, which is the durable record. What must not
      // happen is the device ending up un-subscribed because of it.
      uploaded = false;
    }
    if (deactivated()) return SyncActivation.deactivated;
    await _startListeners(gtdClient, preferencesClient);
    if (deactivated()) {
      // Sign-out landed while the sockets were opening. Run the teardown again
      // rather than leave listeners this instance has already stopped tracking:
      // every step of it is idempotent.
      await deactivate();
      return SyncActivation.deactivated;
    }
    return uploaded ? SyncActivation.active : SyncActivation.uploadIncomplete;
  }

  /// Stop listening and stop authoring — sign-out, or provider disposal.
  ///
  /// The marker is deliberately left alone: it records what this device did for
  /// an account, and signing out does not un-author it.
  ///
  /// It does not wait on an activation in flight — that one may be blocked on a
  /// network round trip, and a sign-out cannot hang on the server it is signing
  /// out of. It invalidates it instead: [_generation] is what makes the abandoned
  /// sequence stop at its next step rather than finish binding and subscribing.
  Future<void> deactivate() async {
    _generation++;
    _pendingFlush?.cancel();
    _pendingFlush = null;
    _capture
      ..onOpAuthored = null
      ..unbind();
    final listeners = [..._listeners];
    _listeners.clear();
    for (final listener in listeners) {
      await listener.dispose();
    }
  }

  // --- step 2 ---------------------------------------------------------------

  /// Mint a member credential from the stored keys, unless one is already in
  /// hand.
  ///
  /// Deliberately here and not in `enrolment.dart`: a fresh ceremony already
  /// takes one as step 5, and what is missing is the *relaunch* case, which is a
  /// lifecycle concern rather than an enrolment one. The preferences client picks
  /// the transport up through `SyncStack`'s factory, which attaches on every
  /// call — see its own comment for why that cannot move into construction.
  Future<void> _attachMemberTransportIfAbsent() async {
    if (_stack.defaultClient.isEnrolled) return;
    final identity = _stack.identity;
    final nonce =
        await _stack.userTransport.requestMemberChallenge(identity.memberId);
    _stack.defaultClient.useMemberTransport(
      await _stack.userTransport.completeMemberChallenge(
        memberId: identity.memberId,
        nonce: nonce,
        signature: await identity.signTransportChallenge(nonce),
      ),
    );
  }

  // --- step 5 ---------------------------------------------------------------

  Future<void> _uploadIfMarkerUnset({
    required SyncClient gtdClient,
    required SyncClient preferencesClient,
  }) async {
    if (await _markers.isComplete(_stack.userId)) return;

    Future<Map<String, Map<String, Object?>>> readReduced(String collection) =>
        _registry.register(collection).readAll();

    final plan = await buildInitialUploadPlan(
      readLegacyRows: _readDomainRows,
      userId: _stack.userId,
      preferencesWorkspaceId: preferencesClient.workspaceId,
      mintTagId: _mintTagId,
      spineLabelTagsByName: await readSpineLabelTags(readReduced),
    );
    final report = await runInitialUpload(
      plan: plan,
      gtdClient: gtdClient,
      preferencesClient: preferencesClient,
      readReducedCollection: readReduced,
    );
    await _markers.markComplete(
      userId: _stack.userId,
      completedAtUtcMs: _stack.nowMs(),
      report: report,
    );
  }

  /// Unfiltered on purpose (#582's rule): a row stranded at `user_id = 'local'`,
  /// or under a previous account's id, has to reach the plan. The transform
  /// stamps the enrolled account at authoring.
  Future<List<Map<String, Object?>>> _readDomainRows(String table) async {
    final rows = await _domain.customSelect('SELECT * FROM $table').get();
    return [for (final row in rows) Map<String, Object?>.of(row.data)];
  }

  // --- step 6 ---------------------------------------------------------------

  Future<void> _startListeners(
    SyncClient gtdClient,
    SyncClient preferencesClient,
  ) async {
    if (_listeners.isNotEmpty) return;
    // One listener per Workspace, because one socket is per Workspace: a poke on
    // the default Workspace's signal says nothing about the preferences log.
    //
    // Recorded only once *both* are up, because `_listeners` being non-empty is
    // what makes this a no-op next time: retaining a listener whose `start()`
    // threw would spend the retry the header's step 6 promises on a socket that
    // never opened, for the life of this instance.
    final started = <SignalListener>[];
    try {
      for (final client in [gtdClient, preferencesClient]) {
        final listener = SignalListener(
          client: client,
          transport: _signalTransport ?? client.transport,
          delay: _listenerDelay,
        );
        await listener.start();
        started.add(listener);
      }
    } on Object {
      for (final listener in started) {
        await listener.dispose();
      }
      rethrow;
    }
    _listeners.addAll(started);
  }

  /// Debounced, and re-armed rather than extended: the first authored op of a
  /// burst decides when the POST goes out, so a steady stream of writes cannot
  /// postpone the flush indefinitely.
  void _scheduleOutboxFlush() {
    if (_pendingFlush?.isActive ?? false) return;
    _pendingFlush = _timerFactory(_flushDebounce, () {
      _pendingFlush = null;
      unawaited(_flushOutboxes());
    });
  }

  Future<void> _flushOutboxes() async {
    if (!_capture.isBound) return;
    try {
      await _stack.defaultClient.flushOutbox();
      final preferencesClient = await _stack
          .workspaceClientFactory(userPreferencesWorkspaceId(_stack.userId));
      await preferencesClient.flushOutbox();
    } on Object {
      // The outbox is durable by contract, so a failed flush is a retry the next
      // authored op or the next poke-driven sync makes. Rethrowing here would
      // land in a timer callback with nobody to catch it.
    }
  }

  /// Flush now rather than on the debounce — what a test uses instead of waiting
  /// out a timer, and what an app-lifecycle "going to background" hook calls when
  /// one lands.
  Future<void> flushOutboxNow() async {
    _pendingFlush?.cancel();
    _pendingFlush = null;
    await _flushOutboxes();
  }
}
