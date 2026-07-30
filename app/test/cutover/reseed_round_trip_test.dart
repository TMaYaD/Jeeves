/// The reseed, end to end: a seeded legacy store authored onto the spine, then
/// the server log reduced from zero and compared with the source.
///
/// **Cutover tooling — removed by #556.**
///
/// Everything here runs the production path. The clients are a real `SimDevice`'s
/// — enrolled through the real ceremony against `FakeSyncServer` — the ops go
/// through `SyncClient.capture`, and the verification builds the same scratch
/// stack `RiverpodReseedRunner` builds, over in-memory stores instead of native
/// ones. The legacy store is a real SQLite database with PowerSync's actual view
/// shape (all TEXT, no NOT NULL), which is what makes the held-back case
/// representable at all.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/initial_upload_plan.dart';
import 'package:jeeves/cutover/reseed/reseed_report.dart';
import 'package:jeeves/cutover/reseed/reseed_runner.dart';
import 'package:jeeves/sync/initial_upload.dart';
import 'package:jeeves/cutover/reseed/reseed_verifier.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';
import 'package:uuid/uuid.dart';

import '../sync/harness/sim_device.dart';
import '../sync/harness/sim_workspace.dart';
import 'reseed_legacy_store.dart';

const Uuid _uuid = Uuid();

/// Canonical lowercase UUIDs derived from readable labels: `OpPayload.decode`
/// refuses anything else as an entity id, and a failure message naming
/// `areaHome` is worth more than one naming a random v4.
String _id(String label) =>
    _uuid.v5(Namespace.url.value, 'jeeves-test://reseed/$label');

final String areaHomeId = _id('tag/area-home');
final String areaWorkId = _id('tag/area-work');
final String areaAdminId = _id('tag/area-admin');
final String labelHomeId = _id('tag/label-home');
final String labelErrandsId = _id('tag/label-errands');
final String multiAreaOutcomeId = _id('todo/multi-area');
final String singleAreaOutcomeId = _id('todo/single-area');
final String edgeTimestampOutcomeId = _id('todo/edge-timestamps');
final String captureId = _id('capture/one');
final String actionId = _id('action/one');
final String focusSessionId = _id('focus-session/one');
final String timeLogId = _id('time-log/one');

/// A deterministic minter for the Labels ADR-0025 has to create.
///
/// Canonical UUIDs, because a minted Tag is authored as an entity like any other
/// — and derived from a counter so the plan is reproducible across runs, which is
/// what lets the second leg assert "nothing was minted twice".
String Function() _mintedTagIds() {
  var minted = 0;
  return () => _id('tag/minted-label-${++minted}');
}

void main() {
  group('reseed round trip', () {
    late SimWorkspace workspace;
    late SimDevice device;
    late SyncClient preferencesClient;
    late ReseedLegacyStore legacy;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      device = workspace.a;
      preferencesClient = await device.preferencesClient;
      // Production's `SyncStack` builds its clients **headless** on purpose: the
      // live `GtdDatabase` is PowerSync-backed, so a projector attached during
      // Phase 2 would tee every reseeded entity straight back into PowerSync's
      // upload queue and the old backend. The harness attaches one because its
      // own tests need it; detaching here is what makes this run the production
      // shape rather than a dual write.
      device.client.projector = null;
      preferencesClient.projector = null;
      legacy = ReseedLegacyStore.open();
      _seedCleanStore(legacy);
    });

    tearDown(() async {
      legacy.close();
      await workspace.close();
    });

    /// One run through the production orchestration.
    Future<ReseedOutcome> reseed({
      String Function()? mintTagId,
      int flushEveryOpCount = initialUploadFlushEveryOpCount,
    }) =>
        runReseed(
          readLegacyRows: legacy.readRows,
          gtdClient: device.client,
          preferencesClient: preferencesClient,
          readReducedCollection: (collection) =>
              device.registry.register(collection).readAll(),
          buildScratchStack: (workspaceId) =>
              _buildScratchStack(device, workspaceId),
          // No PowerSync engine in the Dart harness, so the queue count is
          // unknown rather than zero — and `null == null` still proves it did
          // not change.
          powerSyncUploadQueueCount: () async => null,
          mintTagId: mintTagId ?? _mintedTagIds(),
          flushEveryOpCount: flushEveryOpCount,
        );

    test('reduces the server log from zero to exactly the legacy store',
        () async {
      final outcome = await reseed();

      expect(
        outcome.verdict,
        ReseedVerdict.reseededAndConverged,
        reason: 'tables: ${[
          for (final table in outcome.divergedTables) table.toJson(),
        ]}',
      );
      for (final table in outcome.tables) {
        expect(table.converged, isTrue, reason: '${table.toJson()}');
      }
      // Both Workspaces reported on: eleven GTD collections plus preferences.
      expect(
        outcome.tables.map((table) => table.table),
        containsAll(initialUploadCollectionOrder),
      );

      // Every planned entity authored, nothing skipped on a first run.
      final upload = outcome.upload!;
      expect(upload.authoredOpCount, upload.plannedEntityCount);
      expect(upload.skippedEntityCount, 0);
      expect(upload.reassertedEntityCount, 0);
      expect(upload.refusedEntityCount, 0);

      // Read-only on the legacy side, by observation.
      expect(outcome.readOnlyProof.unchanged, isTrue);
      expect(outcome.plan.excludedRowCount, 0);

      // The report is the acceptance artifact, so it has to survive a JSON
      // round trip intact.
      final json = jsonDecode(jsonEncode(outcome.toJson()))
          as Map<String, dynamic>;
      expect(json['verdict'], outcome.verdict.name);
      expect(json['read_only_proof']['unchanged'], isTrue);
      expect(json['declared_exclusions'], isA<Map<String, dynamic>>());
    });

    test('resolves the multi-Area Outcome per ADR-0025 and enumerates it',
        () async {
      final outcome = await reseed();
      final plan = outcome.plan;

      expect(plan.resolutions, hasLength(1));
      final resolution = plan.resolutions.single;
      expect(resolution.outcomeId, multiAreaOutcomeId);
      expect(resolution.outcomeTitle, 'Three Areas at once');
      // `(casefolded name, id)`: 'admin' sorts before 'Home' and 'Work', and the
      // casefold is what puts the lowercase Area first rather than last.
      expect(resolution.keptArea.name, 'admin');
      expect(resolution.keptArea.id, areaAdminId);

      expect(resolution.converted, hasLength(2));
      final byArea = {
        for (final conversion in resolution.converted)
          conversion.area.name: conversion,
      };
      // 'Home' has a legacy Label of the same name: merge onto it, keeping the
      // user's own Label id and colour.
      expect(byArea['Home']!.labelOrigin, labelOriginLegacyTag);
      expect(byArea['Home']!.label.id, labelHomeId);
      // 'Work' has none anywhere, so a Label is minted.
      expect(byArea['Work']!.labelOrigin, labelOriginMinted);
      expect(byArea['Work']!.label.name, 'Work');

      expect(plan.areaMembershipsConverted, 2);
      expect(plan.labelsMerged, 1);
      expect(plan.labelsMinted, 1);

      // The surplus Area memberships are gone and the Label ones are there.
      final mintedLabelId = byArea['Work']!.label.id;
      final memberships = {
        for (final entity in plan.entitiesFor(todoTagsCollection))
          '${entity.fields['todo_id']} ${entity.fields['tag_id']}',
      };
      expect(memberships, contains('$multiAreaOutcomeId $areaAdminId'));
      expect(memberships, contains('$multiAreaOutcomeId $labelHomeId'));
      expect(memberships, contains('$multiAreaOutcomeId $mintedLabelId'));
      expect(memberships, isNot(contains('$multiAreaOutcomeId $areaHomeId')));
      expect(memberships, isNot(contains('$multiAreaOutcomeId $areaWorkId')));
      // The Area Tags themselves still upload: another Outcome may hold one as
      // its only Area, and an Area with no members is still the user's list of
      // responsibilities.
      final tagIds = {
        for (final entity in plan.entitiesFor(tagsCollection)) entity.entityId,
      };
      expect(tagIds, containsAll([areaHomeId, areaWorkId, areaAdminId]));
    });

    test('collapses a pre-derivation duplicate junction row onto one entity',
        () async {
      final outcome = await reseed();
      // Two legacy rows for (single-area Outcome, Work) with random ids.
      final collapsed = outcome.plan.anomalies
          .where((anomaly) => anomaly.kind == collapsedDuplicateRow)
          .toList();
      expect(collapsed, hasLength(1));
      expect(collapsed.single.table, todoTagsCollection);
      expect(
        outcome.plan
            .entitiesFor(todoTagsCollection)
            .where((entity) =>
                entity.fields['todo_id'] == singleAreaOutcomeId &&
                entity.fields['tag_id'] == areaWorkId),
        hasLength(1),
      );
      expect(outcome.verdict, ReseedVerdict.reseededAndConverged);
    });

    test(
        'an interrupted run completes without double-authoring or forking the '
        'chain', () async {
      // The crash window that matters: everything authored and reduced locally,
      // nothing acknowledged by the server. Offline makes `capture()` succeed
      // (it is purely local) and the flush fail.
      device.goOffline();
      final plan = await buildInitialUploadPlan(
        readLegacyRows: legacy.readRows,
        userId: device.userId,
        preferencesWorkspaceId: preferencesClient.workspaceId,
        mintTagId: _mintedTagIds(),
      );
      await expectLater(
        runInitialUpload(
          plan: plan,
          gtdClient: device.client,
          preferencesClient: preferencesClient,
          readReducedCollection: (collection) =>
              device.registry.register(collection).readAll(),
        ),
        throwsA(isA<SyncTransportException>()),
      );

      device.goOnline();
      final outcome = await reseed();

      // Not one op re-authored: the interrupted run's work is in reduced state,
      // so the diff skips all of it. The second plan is one entity shorter — the
      // Label the first run *minted* has no legacy row, so this run merges onto it
      // by name and endorses it rather than asserting it again.
      expect(outcome.upload!.authoredOpCount, 0);
      expect(
        outcome.upload!.skippedEntityCount,
        outcome.plan.entities.length,
      );
      expect(outcome.plan.entities, hasLength(plan.entities.length - 1));
      expect(
        outcome.plan.endorsedEntityIdsByCollection[tagsCollection],
        hasLength(1),
      );
      expect(outcome.verdict, ReseedVerdict.reseededAndConverged);

      // One content op per entity the *interrupted* run planned, so nothing was
      // authored twice — and an unforked chain, since a second envelope claiming
      // a spent `author_seq` would have been refused rather than stored.
      expect(
        _serverContentOpCount(workspace),
        plan.entities.length,
        reason: 'planned: ${_plannedByCollection(plan)}; '
            'server: ${_serverContentOpsByCollection(workspace)}',
      );
      expect((await device.client.health()).unresolvedAlarmCount, 0);
      expect((await device.client.health()).pendingOpCount, 0);
    });

    test('a legacy edit between runs re-asserts exactly one entity', () async {
      await reseed();
      legacy.update(
        'todos',
        edgeTimestampOutcomeId,
        'title',
        'edited on the old stack',
      );

      final outcome = await reseed();
      expect(outcome.upload!.authoredOpCount, 1);
      expect(outcome.upload!.reassertedEntityCount, 1);
      expect(
        outcome.upload!.skippedEntityCount,
        outcome.plan.entities.length - 1,
      );
      expect(outcome.verdict, ReseedVerdict.reseededAndConverged);
      // Field-grain LWW converged on the re-asserted value.
      final reduced = await device.registry
          .register(todosCollection)
          .readEntity(edgeTimestampOutcomeId);
      expect(reduced!['title'], 'edited on the old stack');
    });

    test('a re-run mints no second Label for the same converted Area',
        () async {
      await reseed();
      // A fresh minter: if the second run minted again it would produce
      // `minted-label-1` a second time and the plan would carry two Labels for
      // 'Work'. Finding the first run's Label in the spine's reduced Tags is what
      // prevents that.
      final outcome = await reseed(mintTagId: _mintedTagIds());
      expect(outcome.plan.labelsMinted, 0);
      expect(outcome.plan.labelsMerged, 2);
      expect(
        outcome.plan.resolutions.single.converted
            .map((conversion) => conversion.labelOrigin),
        containsAll([labelOriginLegacyTag, labelOriginSpineTag]),
      );
      expect(outcome.verdict, ReseedVerdict.reseededAndConverged);
    });

    test('a NULL required column leaves the row behind and says so', () async {
      final untitledId = _id('todo/untitled');
      legacy.insert('todos', {
        'id': untitledId,
        // No title at all — a state PowerSync's view can genuinely hold, and one
        // no op could ever project.
        'created_at': '2026-07-20T09:00:00.000Z',
        'clarified': 1,
        'intent': 'next',
        'user_id': 'legacy-user',
      });

      final outcome = await reseed();

      expect(outcome.verdict, ReseedVerdict.partiallyReseeded);
      expect(outcome.plan.excludedRowIdsByTable[todosCollection],
          [untitledId]);
      expect(
        outcome.plan.anomalies.where((anomaly) =>
            anomaly.kind == nullRequiredColumn && anomaly.column == 'title'),
        hasLength(1),
      );
      // The row is not in the plan, so it cannot be silently "converged" — and
      // every table that *is* compared still agrees.
      expect(
        outcome.plan
            .entitiesFor(todosCollection)
            .map((entity) => entity.entityId),
        isNot(contains(untitledId)),
      );
      for (final table in outcome.tables) {
        expect(table.converged, isTrue, reason: '${table.toJson()}');
      }
    });

    test('preferences are authored into their own Workspace and converge',
        () async {
      final outcome = await reseed();
      final preferences =
          outcome.plan.entitiesFor(userPreferencesCollection).toList();
      expect(preferences, isNotEmpty);
      for (final entity in preferences) {
        expect(entity.workspace, InitialUploadWorkspace.preferences);
        // ADR-0033: a value write names the key that selects its merge strategy,
        // or every peer quarantines it. Plus `user_id` and `updated_at`, which
        // `PreferencesStore.set` does not write — the reseed has to satisfy the
        // codec's required columns so the entity projects for verification.
        expect(entity.fields.keys,
            containsAll(['key', 'value', 'user_id', 'updated_at']));
      }
      final table = outcome.tables
          .firstWhere((diff) => diff.table == userPreferencesCollection);
      expect(table.converged, isTrue, reason: '${table.toJson()}');
      expect(table.projectedRowCount, preferences.length);
    });
  });
}

/// The same scratch stack `RiverpodReseedRunner` assembles, over in-memory
/// stores: the live device's identity, clock and member transport, its Root pin
/// copied in, and a projector into a scratch domain store that keeps the default
/// `NoopDomainOpCapture`.
Future<ReseedScratchStack> _buildScratchStack(
  SimDevice device,
  String workspaceId,
) async {
  final live = await device.workspaceClientFactory(workspaceId);
  final rootPk = await live.pinnedRootPk();
  return assembleReseedScratchStack(
    workspaceId: workspaceId,
    userId: device.userId,
    identity: device.identity,
    clock: device.hlc,
    nowMs: () => device.clock.nowMs,
    transport: device.link,
    pinnedRootPk: rootPk!,
    escrowVersion: await live.highestEscrowVersionSeen(),
    syncDatabase: SyncDatabase(NativeDatabase.memory()),
    domain: GtdDatabase(NativeDatabase.memory()),
  );
}

/// Content ops the server holds, across both Workspaces — the direct measure of
/// "nothing was authored twice".
int _serverContentOpCount(SimWorkspace workspace) => workspace.server.storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .length;

Map<String, int> _plannedByCollection(InitialUploadPlan plan) {
  final counts = <String, int>{};
  for (final entity in plan.entities) {
    counts[entity.collection] = (counts[entity.collection] ?? 0) + 1;
  }
  return counts;
}

/// The same tally taken off the signed envelopes the server holds, so a mismatch
/// names the collection rather than only the total.
Map<String, int> _serverContentOpsByCollection(SimWorkspace workspace) {
  final counts = <String, int>{};
  for (final op in workspace.server.storedOps) {
    if (op.header?.opClass != opClassContent) continue;
    final payload =
        OpPayload.decode(parseBody(splitEnvelope(op.envelope).body));
    counts[payload.collection] = (counts[payload.collection] ?? 0) + 1;
  }
  return counts;
}

/// A store with no unreseedable rows: representative data across all twelve
/// tables, a three-Area Outcome, a Label sharing a name with an Area, a
/// pre-derivation duplicate junction row, and timestamp edge values.
void _seedCleanStore(ReseedLegacyStore legacy) {
  const user = 'legacy-user';

  legacy
    ..insert('tags', {
      'id': areaAdminId,
      // Lowercase on purpose: the primary-Area pick casefolds, so this Area
      // sorts first and a case-sensitive comparison would pick 'Home'.
      'name': 'admin',
      'color': '#0EA5E9',
      'type': 'area',
      'user_id': user,
    })
    ..insert('tags', {
      'id': areaHomeId,
      'name': 'Home',
      'color': '#22C55E',
      'type': 'area',
      'user_id': user,
    })
    ..insert('tags', {
      'id': areaWorkId,
      'name': 'Work',
      'color': '#F97316',
      'type': 'area',
      'user_id': user,
    })
    ..insert('tags', {
      'id': labelHomeId,
      // Shares its name with the 'Home' Area: the conversion must merge onto
      // this Label rather than mint a second one.
      'name': 'Home',
      'color': '#A855F7',
      'type': 'label',
      'user_id': user,
    })
    ..insert('tags', {
      'id': labelErrandsId,
      'name': 'Errands',
      'color': null,
      'type': 'label',
      'user_id': user,
    });

  legacy
    ..insert('todos', {
      'id': multiAreaOutcomeId,
      'title': 'Three Areas at once',
      'notes': 'Carries a tab\tand a newline\nin its notes',
      'priority': 2,
      'due_date': '2026-08-01T00:00:00.000Z',
      'created_at': '2026-07-01T08:30:00.000Z',
      'updated_at': '2026-07-02T08:30:00.000Z',
      'done_at': null,
      'clarified': 1,
      'intent': 'next',
      'time_estimate': 45,
      'energy_level': 'high',
      'capture_source': 'manual',
      'location_id': null,
      'user_id': user,
      'last_clarified_at': '2026-07-02T08:30:00.000Z',
      'last_next_action_completion_at': null,
      // Excluded from the wire by ADR-0030; the projector supplies the default.
      'time_spent_minutes': 17,
    })
    ..insert('todos', {
      'id': singleAreaOutcomeId,
      'title': 'One Area only',
      'created_at': '2026-07-03T08:30:00.000Z',
      'clarified': 1,
      'intent': 'maybe',
      // A row that never synced, stranded under the placeholder user. It has to
      // reach the plan — the stamping is what carries it to the right account.
      'user_id': 'local',
    })
    ..insert('todos', {
      'id': edgeTimestampOutcomeId,
      'title': 'Timestamp edges',
      // Microseconds (truncated, never rounded) and a non-UTC offset: both are
      // shapes the legacy store genuinely holds.
      'created_at': '2026-07-04T08:30:00.123456Z',
      'updated_at': '2026-07-04 10:30:00.999999+02:00',
      // A TEXT timestamp column: opaque pass-through, byte for byte.
      'done_at': '2026-07-05T11:22:33.444Z',
      'clarified': 1,
      'intent': 'next',
      'user_id': user,
    });

  legacy
    ..insert('todo_tags', {
      'id': _id('todo-tag/multi-admin'),
      'todo_id': multiAreaOutcomeId,
      'tag_id': areaAdminId,
      'user_id': user,
    })
    ..insert('todo_tags', {
      'id': _id('todo-tag/multi-home'),
      'todo_id': multiAreaOutcomeId,
      'tag_id': areaHomeId,
      'user_id': user,
    })
    ..insert('todo_tags', {
      'id': _id('todo-tag/multi-work'),
      'todo_id': multiAreaOutcomeId,
      'tag_id': areaWorkId,
      'user_id': user,
    })
    ..insert('todo_tags', {
      'id': _id('todo-tag/multi-errands'),
      'todo_id': multiAreaOutcomeId,
      'tag_id': labelErrandsId,
      'user_id': user,
    })
    // The same pair twice, under two random ids a pre-derivation device minted.
    // They collapse onto `todoTagIdFor(todo, tag)`.
    ..insert('todo_tags', {
      'id': _id('todo-tag/single-work-a'),
      'todo_id': singleAreaOutcomeId,
      'tag_id': areaWorkId,
      'user_id': user,
    })
    ..insert('todo_tags', {
      'id': _id('todo-tag/single-work-b'),
      'todo_id': singleAreaOutcomeId,
      'tag_id': areaWorkId,
      'user_id': user,
    });

  legacy.insert('actions', {
    'id': actionId,
    'outcome_id': multiAreaOutcomeId,
    'user_id': user,
    'text': 'Draft the thing',
    'role': 'current',
    'position': 0,
    'energy_level': 'medium',
    'time_estimate': 20,
    'created_at': '2026-07-01T09:00:00.000Z',
    'updated_at': null,
    'done_at': null,
  });

  legacy
    ..insert('captures', {
      'id': captureId,
      'title': 'Something to think about',
      'notes': null,
      'capture_source': 'share_sheet',
      'created_at': '2026-06-30T20:00:00.000Z',
      'clarified_at': '2026-07-01T08:00:00.000Z',
      'updated_at': null,
      'user_id': user,
    })
    ..insert('capture_outcomes', {
      'id': _id('capture-outcome/one'),
      'capture_id': captureId,
      'outcome_id': multiAreaOutcomeId,
      'created_at': '2026-07-01T08:00:00.000Z',
      'user_id': user,
    })
    ..insert('capture_tags', {
      'id': _id('capture-tag/one'),
      'capture_id': captureId,
      'tag_id': labelErrandsId,
      'user_id': user,
    });

  legacy
    ..insert('focus_sessions', {
      'id': focusSessionId,
      'user_id': user,
      'started_at': '2026-07-06T09:00:00.000Z',
      // Still open: a null `ended_at` is a legal field value, not an absence.
      'ended_at': null,
      'current_task_id': multiAreaOutcomeId,
    })
    ..insert('focus_session_tasks', {
      'id': _id('focus-session-task/one'),
      'focus_session_id': focusSessionId,
      'task_id': multiAreaOutcomeId,
      'position': 0,
      'disposition': null,
      'user_id': user,
    })
    ..insert('focus_session_dispositions', {
      'id': _id('focus-session-disposition/one'),
      'focus_session_id': focusSessionId,
      'task_id': multiAreaOutcomeId,
      'disposition': 'rollover',
      'user_id': user,
    })
    ..insert('time_logs', {
      'id': timeLogId,
      'user_id': user,
      'task_id': multiAreaOutcomeId,
      'action_id': actionId,
      'started_at': '2026-07-06T09:05:00.000Z',
      'ended_at': null,
      'focus_session_id': focusSessionId,
    });

  legacy
    ..insert('user_preferences', {
      'id': _id('preference/clarify-mode'),
      'user_id': user,
      'key': 'clarify_mode',
      'value': '"oneToOne"',
      'updated_at': '2026-07-01T07:00:00.000Z',
    })
    ..insert('user_preferences', {
      // A random id a pre-#550 device minted: the derivation realigns it.
      'id': _id('preference/planning-time-random'),
      'user_id': user,
      'key': 'daily_planning_time',
      'value': '"08:00"',
      'updated_at': '2026-07-01T07:00:00.000Z',
    });
}
