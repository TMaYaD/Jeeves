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

  /// Open a capture scope. Scopes nest; only the outermost flushes.
  void beginScope();

  /// Close the innermost scope, emitting the coalesced ops when it was the
  /// outermost. Awaited inside the same continuation as the commit so op
  /// authoring order matches domain write order.
  Future<void> commitScope();

  /// Abandon the innermost scope, discarding everything recorded inside it.
  void rollbackScope();
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
  void beginScope() {}

  @override
  Future<void> commitScope() async {}

  @override
  void rollbackScope() {}
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
  final List<CapturedOp> _pending = <CapturedOp>[];
  final List<int> _scopeMarks = <int>[];

  /// Emit one coalesced op. Called in recorded order, after commit.
  Future<void> emit(CapturedOp op);

  CapturedOp _slotFor(String collection, String entityId) {
    final mark = _scopeMarks.isEmpty ? 0 : _scopeMarks.first;
    for (var index = _pending.length - 1; index >= mark; index--) {
      final candidate = _pending[index];
      if (candidate.collection == collection && candidate.entityId == entityId) {
        return candidate;
      }
    }
    final fresh = CapturedOp._(collection, entityId);
    _pending.add(fresh);
    return fresh;
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
  void beginScope() => _scopeMarks.add(_pending.length);

  @override
  Future<void> commitScope() async {
    _scopeMarks.removeLast();
    if (_scopeMarks.isNotEmpty) return;
    final flushing = List<CapturedOp>.of(_pending);
    _pending.clear();
    for (final op in flushing) {
      // A write that coalesced away to nothing (all its fields overwritten by a
      // later tombstone, then revived with no fields) carries no effect.
      if (!op.tombstone && op.fields.isEmpty) continue;
      await emit(op);
    }
  }

  @override
  void rollbackScope() {
    final mark = _scopeMarks.removeLast();
    _pending.removeRange(mark, _pending.length);
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
