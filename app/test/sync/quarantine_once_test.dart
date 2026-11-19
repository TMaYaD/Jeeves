/// #989: one refused op is filed once, however many pulls fetch it.
///
/// A refusal is filed in `quarantined_ops`, and the dedupe that keeps one
/// refusal to one row used to be a read followed by an insert with nothing
/// between them. Two pulls that fetched the same op therefore both decided to
/// insert, and the user's quarantine screen showed the same refusal twice.
///
/// The overlap is not exotic: the signal listener pulls on a poke while a
/// manual sync is in flight, both read the same cursor, and both fetch the same
/// ops. It was first seen in the #980 tests, where the in-process fake server's
/// `injectUnchecked` pokes its subscribers.
///
/// These tests pin the property from both sides — one row for one refused op
/// however many pulls race for it, and *two* rows for two different ops that
/// share a seq and a reason, because the dedupe is about the op and never about
/// the slot.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/sync_rejection.dart';

import 'harness/author_fixture.dart';
import 'harness/sim_workspace.dart';

void main() {
  late SimWorkspace workspace;

  setUp(() async {
    workspace = await SimWorkspace.create(deviceCount: 1);
    await workspace.syncAll();
  });

  tearDown(() async {
    await workspace.close();
  });

  /// An author this device has no Root-signed registration for, so every op it
  /// authors is refused as `member_not_chained_to_root`.
  Future<AuthorFixture> stranger({int seedByte = 11}) async =>
      AuthorFixture.create(
        seed: Uint8List.fromList(
          List<int>.generate(32, (index) => index + seedByte),
        ),
      );

  test('two pulls that fetch the same refused op file it once', () async {
    final author = await stranger();
    workspace.server.injectUnchecked(
      workspace.workspaceId,
      await author.nextEnvelope(workspace.workspaceId),
    );

    // Two pulls at once. Both are issued before either has moved the cursor, so
    // both fetch the same op — the overlap a poke-driven pull and a manual sync
    // produce in the field, without the timing a real socket would add.
    final first = workspace.a.client.pull();
    final second = workspace.a.client.pull();
    await Future.wait([first, second]);

    final rows = await workspace.a.client.quarantined(includeReleased: false);
    expect(
      rows,
      hasLength(1),
      reason: 'one refused op is one row, however many pulls fetched it',
    );
    expect(
      rows.single.reason,
      SyncRejectionReason.memberNotChainedToRoot.code,
      reason: 'the op is refused, and refused for the reason it earned',
    );
  });

  test('two different ops at one seq with one reason are two rows', () async {
    // The dedupe is about the *op*, not the slot: two different envelopes
    // refused for the same reason at the same transport seq are two refusals,
    // and neither may be dropped to make the table tidy.
    final author = await stranger();
    final first = await author.nextEnvelope(workspace.workspaceId);
    final second = await author.nextEnvelope(workspace.workspaceId);
    expect(first, isNot(equals(second)), reason: 'two different envelopes');

    final seq = workspace.server.injectUnchecked(
      workspace.workspaceId,
      first,
    );
    workspace.server.injectUnchecked(workspace.workspaceId, second, atSeq: seq);

    await workspace.a.client.pull();

    final rows = await workspace.a.client.quarantined(includeReleased: false);
    expect(rows, hasLength(2), reason: 'neither refusal may be dropped');
    expect(
      rows.map((row) => row.seq).toSet(),
      {seq},
      reason: 'both refusals sit at the seq the server spent twice',
    );
    expect(
      rows.map((row) => row.reason).toSet(),
      {SyncRejectionReason.memberNotChainedToRoot.code},
    );
  });
}
