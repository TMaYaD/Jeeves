/// The seam every DAO write path describes its domain effect through.
///
/// The production binding is [NoopDomainOpCapture]: the live app still writes
/// through PowerSync until the cutover in #553, and teeing writes into both
/// paths would be exactly the dual-write branching the Implementation stance
/// forbids. The seam exists now so #553's flip is one construction-site change
/// — build `GtdDatabase` with `SyncOpCapture(syncClient)` instead of the no-op
/// — and so the harness can drive the whole app through the op log today.
///
/// **Buffered until commit.** Calls made inside a DAO transaction accumulate
/// and are emitted only once the transaction commits: a rolled-back write must
/// never be signed and queued. The flush coalesces every write to one entity
/// within a transaction into a single op, so a method that touches a row three
/// times authors one op, not three.
///
/// **Scopes are token-bound.** Two `capturing` calls can overlap, so neither
/// "the innermost scope" nor a shared buffer of marks identifies a scope; see
/// [CaptureScope].
library;

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

/// The production binding: records nothing, emits nothing.
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

/// The real binding #553 flips on: every coalesced effect becomes a signed op.
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
