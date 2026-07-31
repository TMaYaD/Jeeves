/// The seam every DAO write path describes its domain effect through.
///
/// The production binding is [WorkspaceRoutingOpCapture]: one instance built at
/// the `GtdDatabase` construction site, buffering the ops it is handed until the
/// enrolment decision is made — bound to this device's two Workspace clients once
/// it is enrolled (which drains the buffer), settled silent once it is not (which
/// discards it). A *decision*, never launch timing, disposes of an op, so a write
/// on the very first turn of a cold start cannot fall through the window before
/// the lifecycle binds. [NoopDomainOpCapture] remains what a caller passes when it
/// means "never author", which is every test that is not about capture.
///
/// **The scope is the transaction.** `GtdDatabase.capturing` runs its body
/// inside a real transaction, so a capture scope and a transaction have the
/// same lifetime. Calls made inside it accumulate and are emitted only once the
/// transaction commits — a rolled-back write is never signed and queued, and a
/// committed write can never lose its op (the two directions issue #598
/// closed). The flush coalesces every write to one entity within the scope into
/// a single op, so a method that touches a row three times authors one op, not
/// three. A bare `GtdDatabase.transaction` opened outside a capturing zone is
/// refused; the projector's op-free writes use `GtdDatabase.uncapturedTransaction`.
/// That guard binds db-object callers only (a DAO is a `DatabaseAccessor`, so a
/// DAO-internal bare `transaction` would dispatch past the override) — moot in
/// practice, since no DAO spells `transaction`.
///
/// **Scopes are token-bound.** Two `capturing` calls can overlap, so neither
/// "the innermost scope" nor a shared buffer of marks identifies a scope; see
/// [CaptureScope].
library;

import 'collection_codecs.dart' show userPreferencesCollection;
import 'sync_client.dart';

/// One coalesced domain effect, ready to be authored as an op.
class CapturedOp {
  CapturedOp._(this.collection, this.entityId);

  final String collection;
  final String entityId;

  final Map<String, Object?> fields = <String, Object?>{};
  bool tombstone = false;

  @override
  String toString() => tombstone
      ? 'CapturedOp($collection/$entityId, tombstone)'
      : 'CapturedOp($collection/$entityId, $fields)';
}

/// A handle to one open capture scope.
///
/// Scopes are **token-bound**, not a bare stack of marks, because two
/// `capturing` calls can be in flight at once: each awaits its own body, but
/// nothing stops two un-awaited callers from overlapping. A stack that closed
/// "the innermost scope" closed whichever scope opened *last* — so an
/// overlapping rollback discarded the other scope's bookkeeping, left its own
/// rolled-back writes in the buffer, and the other scope's commit signed them.
/// A token names one exact scope, so a rollback can only ever discard the writes
/// recorded in that scope.
class CaptureScope {
  CaptureScope._(this._parent);

  /// The scope that was open when this one began, if any. Recorded at begin, so
  /// a later out-of-order close cannot re-parent anybody.
  final CaptureScope? _parent;

  /// This scope's own buffer. Ops merge into the parent's on commit, so the
  /// coalescing a flat buffer gave across nested scopes is preserved.
  final List<CapturedOp> _pending = <CapturedOp>[];

  bool _isOpen = true;

  /// The innermost still-open scope this one's ops belong to on commit, or null
  /// when this scope is the outermost live one and must therefore flush.
  ///
  /// A closed ancestor means the two scopes overlapped rather than nested — real
  /// nesting is always LIFO, because a nested `capturing` is awaited inside its
  /// parent's body — so the ops belong to nobody but this scope.
  CaptureScope? get _flushTarget {
    for (var scope = _parent; scope != null; scope = scope._parent) {
      if (scope._isOpen) return scope;
    }
    return null;
  }
}

/// What a DAO write path calls; what a transaction scope flushes.
///
/// [write] and [tombstone] are the two verbs of the log — an assertion of
/// fields, and a deletion that is an op rather than row absence. The three
/// lifecycle members are how the buffer-until-commit rule is enforced;
/// [GtdDatabase.capturing] is the only caller that should touch them.
abstract interface class DomainOpCapture {
  /// Assert [fields] on `(collection, entityId)`: snake_case column names,
  /// values already encoded per `collection_codecs.dart`.
  void write({
    required String collection,
    required String entityId,
    required Map<String, Object?> fields,
  });

  /// Delete `(collection, entityId)` — a tombstone op, never row absence.
  void tombstone({required String collection, required String entityId});

  /// Open a capture scope, returning the token that closes it. Scopes nest;
  /// only the outermost flushes.
  CaptureScope beginScope();

  /// Close [scope], emitting its coalesced ops when it was the outermost and
  /// merging them into its parent otherwise. Awaited inside the same
  /// continuation as the commit so op authoring order matches domain write
  /// order.
  Future<void> commitScope(CaptureScope scope);

  /// Abandon [scope], discarding everything recorded inside it.
  void rollbackScope(CaptureScope scope);
}

/// The constructor default: records nothing, emits nothing.
///
/// **Not the production binding** — production wires
/// [WorkspaceRoutingOpCapture] into `GtdDatabase` via `domainOpCaptureProvider`
/// (see `providers/database_provider.dart`). This is what `GtdDatabase`'s
/// `opCapture` parameter falls back to when nothing is passed
/// (`database/gtd_database.dart`), which is every test that is not about
/// capture, and any other caller that means "never author."
class NoopDomainOpCapture implements DomainOpCapture {
  const NoopDomainOpCapture();

  @override
  void write({
    required String collection,
    required String entityId,
    required Map<String, Object?> fields,
  }) {}

  @override
  void tombstone({required String collection, required String entityId}) {}

  @override
  CaptureScope beginScope() => _scope;

  @override
  Future<void> commitScope(CaptureScope scope) async {}

  @override
  void rollbackScope(CaptureScope scope) {}

  /// One shared token: the no-op keeps no state, so there is nothing for a
  /// per-call token to identify, and every DAO write path opens a scope.
  static final CaptureScope _scope = CaptureScope._(null);
}

/// Buffering, coalescing and scope bookkeeping — shared by every real binding.
///
/// Coalescing is order-sensitive on purpose: within one transaction a tombstone
/// clears the fields accumulated before it, and a later write revives the
/// entity and clears the tombstone. The emitted op is therefore the
/// transaction's *net* effect on that entity, which is what a single HLC can
/// honestly represent (a tombstone and a field write sharing one clock would
/// leave the field hidden).
abstract class BufferedDomainOpCapture implements DomainOpCapture {
  /// Open scopes, innermost last — writes land in the innermost.
  ///
  /// [write] and [tombstone] carry no token, so attribution is by *ambient*
  /// scope, and the ambient scope of two overlapping ones can only be the one
  /// begun most recently. What tokens buy is that closing a scope can never
  /// touch another's writes; they cannot tell which of two overlapping scopes a
  /// tokenless write belonged to. Ambiguity there needs a scope handle on the
  /// write verbs, which would mean every DAO threading one through.
  final List<CaptureScope> _open = <CaptureScope>[];

  /// Emit one coalesced op. Called in recorded order, after commit.
  Future<void> emit(CapturedOp op);

  /// A write that coalesced away to nothing (all its fields overwritten by a
  /// later tombstone, then revived with no fields) carries no effect.
  static bool _hasEffect(CapturedOp op) => op.tombstone || op.fields.isNotEmpty;

  static CapturedOp _slotIn(
    CaptureScope scope,
    String collection,
    String entityId,
  ) {
    for (var index = scope._pending.length - 1; index >= 0; index--) {
      final candidate = scope._pending[index];
      if (candidate.collection == collection && candidate.entityId == entityId) {
        return candidate;
      }
    }
    final fresh = CapturedOp._(collection, entityId);
    scope._pending.add(fresh);
    return fresh;
  }

  CapturedOp _slotFor(String collection, String entityId) {
    if (_open.isEmpty) {
      throw StateError(
        'Domain effect described outside a capture scope: $collection/$entityId. '
        'Wrap the DAO write path in GtdDatabase.capturing.',
      );
    }
    return _slotIn(_open.last, collection, entityId);
  }

  @override
  void write({
    required String collection,
    required String entityId,
    required Map<String, Object?> fields,
  }) {
    final slot = _slotFor(collection, entityId);
    slot.tombstone = false;
    slot.fields.addAll(fields);
  }

  @override
  void tombstone({required String collection, required String entityId}) {
    final slot = _slotFor(collection, entityId);
    slot.tombstone = true;
    slot.fields.clear();
  }

  @override
  CaptureScope beginScope() {
    final scope = CaptureScope._(_open.isEmpty ? null : _open.last);
    _open.add(scope);
    return scope;
  }

  @override
  Future<void> commitScope(CaptureScope scope) async {
    _close(scope);
    final parent = scope._flushTarget;
    if (parent != null) {
      // Replaying through the same two verbs is what keeps a nested write to an
      // entity the parent already touched one op rather than two.
      for (final op in scope._pending) {
        if (!_hasEffect(op)) continue;
        final slot = _slotIn(parent, op.collection, op.entityId);
        slot.tombstone = op.tombstone;
        if (op.tombstone) {
          slot.fields.clear();
        } else {
          slot.fields.addAll(op.fields);
        }
      }
      return;
    }
    for (final op in scope._pending) {
      if (!_hasEffect(op)) continue;
      await emit(op);
    }
  }

  @override
  void rollbackScope(CaptureScope scope) {
    _close(scope);
    scope._pending.clear();
  }

  void _close(CaptureScope scope) {
    if (!scope._isOpen) {
      throw StateError('Capture scope closed twice.');
    }
    scope._isOpen = false;
    _open.remove(scope);
  }
}

/// One client, every collection: the single-Workspace binding the harness and the
/// capture-contract tests drive. Production uses [WorkspaceRoutingOpCapture],
/// which cannot mis-route a preference write.
class SyncOpCapture extends BufferedDomainOpCapture {
  SyncOpCapture(this.client);

  final SyncClient client;

  @override
  Future<void> emit(CapturedOp op) async {
    await client.capture(
      collection: op.collection,
      entityId: op.entityId,
      fields: op.fields,
      tombstone: op.tombstone,
    );
  }
}

/// Which disposition the routing seam has reached for the ops it is handed.
///
/// The seam is constructed at process start — before sign-in, before the
/// enrolment status has even been read — so its very first state is *neither*
/// "author" nor "drop" but "not yet decided". What disposes of an op is the
/// **decision**, never launch timing: an op emitted before the decision is held,
/// not lost, so no write can fall through the window between the store becoming
/// writable and the lifecycle reaching its bind step.
enum _CaptureDecision {
  /// The enrolment decision has not been made yet. Emitted ops accumulate in
  /// [WorkspaceRoutingOpCapture._pending] until [WorkspaceRoutingOpCapture.bind]
  /// or [WorkspaceRoutingOpCapture.unbind] settles it.
  undecided,

  /// Enrolled: route each op to its Workspace client and author it.
  bound,

  /// Not enrolled (or signed out): author nothing, drop the pending buffer.
  silent,
}

/// The production binding: routes each coalesced effect to the Workspace whose
/// log its entity id belongs to, buffering until the enrolment decision is made
/// and dropping once it is made "author nothing".
///
/// Three reasons this exists rather than `SyncOpCapture(client)`:
///
/// * **Routing.** `UserPreferencesDao` describes its effects into
///   `user_preferences`, whose entity id is `uuid5(preferences_workspace_id,
///   key)`. An op authored into the *GTD* Workspace would land in a log whose id
///   derivation nobody there shares, so two devices would converge on an id
///   neither Workspace holds. Everything else goes to the default Workspace.
/// * **Late binding.** `GtdDatabase` is constructed at process start — before
///   sign-in, before enrolment — so at construction there is no client to route
///   to. `sync_lifecycle.dart` [bind]s it once a device is enrolled, and
///   [unbind] settles it silent on sign-out or an un-enrolled launch.
/// * **A decision, never timing, disposes of an op.** The seam exists before the
///   app can render a frame, so an enrolled device that writes on the very first
///   turn of a cold start must not lose that write to the async chain the
///   lifecycle runs before it reaches [bind]. While [undecided] every emitted op
///   is buffered; [bind] drains the buffer in write order (authoring each, firing
///   [onOpAuthored] so the debounced flush is scheduled) before any live op; and
///   [unbind] discards it. A write landing mid-drain is appended behind the
///   pending tail, so authoring order always matches domain write order.
///
/// It extends [BufferedDomainOpCapture] rather than reimplementing the buffer, so
/// scope, coalescing and rollback semantics are the ones every other binding is
/// tested under; only [emit] varies.
class WorkspaceRoutingOpCapture extends BufferedDomainOpCapture {
  SyncClient? _gtdClient;
  SyncClient? _preferencesClient;

  _CaptureDecision _decision = _CaptureDecision.undecided;

  /// Coalesced ops emitted before the enrolment decision, in emission order.
  /// Drained by [bind], discarded by [unbind]. Also the holding pen for a write
  /// that lands while [bind] is mid-drain, so it authors behind the tail rather
  /// than jumping the queue.
  final List<CapturedOp> _pending = <CapturedOp>[];

  /// True while [bind] is draining [_pending]. A live [emit] during the drain
  /// must append rather than author directly, or it would author ahead of ops
  /// buffered before it and break the write-order contract.
  bool _draining = false;

  /// Called after each authored op, so a caller can schedule an outbox flush
  /// without this class knowing what a flush is. Never called for a dropped op,
  /// and never for a buffered one — it fires at authoring, which for a buffered
  /// op is when [bind] drains it.
  void Function()? onOpAuthored;

  bool get isBound => _decision == _CaptureDecision.bound;

  /// Settle the decision to "author": record the clients, arm [onOpAuthored]
  /// (before the drain, so buffered ops schedule the flush they need), and drain
  /// the pending buffer in write order. Awaited by the lifecycle so a caller can
  /// know the buffer is flushed.
  Future<void> bind({
    required SyncClient gtdClient,
    required SyncClient preferencesClient,
    void Function()? onOpAuthored,
  }) async {
    _gtdClient = gtdClient;
    _preferencesClient = preferencesClient;
    if (onOpAuthored != null) this.onOpAuthored = onOpAuthored;
    _decision = _CaptureDecision.bound;
    await _drainPending();
  }

  /// Settle the decision to "author nothing": drop the clients, discard the
  /// pending buffer, and drop every op from here on. Idempotent — a second call,
  /// or a call from [_CaptureDecision.undecided], is a no-op beyond clearing.
  /// A scope open across the transition still closes cleanly; its ops are
  /// dropped. A later [bind] authors only the writes made after it.
  void unbind() {
    _gtdClient = null;
    _preferencesClient = null;
    _pending.clear();
    _decision = _CaptureDecision.silent;
  }

  Future<void> _drainPending() async {
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        // A deactivate can land mid-drain (its synchronous `unbind` clears the
        // list and settles silent): stop rather than author into a nulled client
        // for an account nobody is signed into any more.
        if (_decision != _CaptureDecision.bound) {
          _pending.clear();
          return;
        }
        final op = _pending.removeAt(0);
        try {
          await _author(op);
        } on Object {
          // Skip-and-continue: a buffered op `capture()` refuses (#573) is a
          // permanent anomaly on that one entity, not a reason to strand every
          // op queued behind it — the same stance as "a refusal does not hold
          // the marker open".
          continue;
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _author(CapturedOp op) async {
    final client = op.collection == userPreferencesCollection
        ? _preferencesClient
        : _gtdClient;
    if (client == null) return;
    await client.capture(
      collection: op.collection,
      entityId: op.entityId,
      fields: op.fields,
      tombstone: op.tombstone,
    );
    onOpAuthored?.call();
  }

  @override
  Future<void> emit(CapturedOp op) async {
    switch (_decision) {
      case _CaptureDecision.undecided:
        _pending.add(op);
      case _CaptureDecision.silent:
        return;
      case _CaptureDecision.bound:
        if (_draining) {
          _pending.add(op);
        } else {
          await _author(op);
        }
    }
  }
}

/// Records the coalesced ops without authoring them — the substrate of the
/// per-DAO capture-contract tests.
class RecordingDomainOpCapture extends BufferedDomainOpCapture {
  final List<CapturedOp> recorded = <CapturedOp>[];

  @override
  Future<void> emit(CapturedOp op) async => recorded.add(op);

  /// `collection/entityId` pairs in emission order — the shape the contract
  /// tests assert against.
  List<String> get keys =>
      [for (final op in recorded) '${op.collection}/${op.entityId}'];

  List<CapturedOp> forCollection(String collection) =>
      [for (final op in recorded) if (op.collection == collection) op];

  void clear() => recorded.clear();
}
