/// The uploader's seams: the diff skip, the flush cadence, and the guard that
/// refuses a preference value carrying no key.
///
/// Integration rather than unit: the clients are a real `SimDevice`'s, so the
/// skip is measured against reduced state the *production* reduce path wrote and
/// the refusal comes out of `Reducer.guardPayload` at the real call site.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/initial_upload_plan.dart';
import 'package:jeeves/sync/initial_upload.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:uuid/uuid.dart';

import '../sync/harness/sim_device.dart';
import '../sync/harness/sim_workspace.dart';

const Uuid _uuid = Uuid();

String _id(String label) =>
    _uuid.v5(Namespace.url.value, 'jeeves-test://reseed-uploader/$label');

void main() {
  group('plannedFieldsAlreadyReduced', () {
    test('a missing entity is never a skip', () {
      expect(plannedFieldsAlreadyReduced({'title': 'a'}, null), isFalse);
    });

    test('compares only the planned fields, ignoring the rest', () {
      // The fold-in that matters: an entity carrying a field the plan says
      // nothing about must still count as already-authored, or the skip counter
      // is a lie and every run re-authors the whole store.
      expect(
        plannedFieldsAlreadyReduced(
          {'title': 'a'},
          {'title': 'a', 'notes': 'written by something else'},
        ),
        isTrue,
      );
    });

    test('a planned null must be present and null, not absent', () {
      // The null convention: the reseed *asserts* the emptiness of a column, so
      // "the field is missing" is not the same claim as "the field is null".
      expect(plannedFieldsAlreadyReduced({'notes': null}, {'notes': null}),
          isTrue);
      expect(plannedFieldsAlreadyReduced({'notes': null}, {}), isFalse);
      expect(plannedFieldsAlreadyReduced({'notes': null}, {'notes': ''}),
          isFalse);
    });

    test('differing scalars of the same shape do not skip', () {
      expect(plannedFieldsAlreadyReduced({'priority': 1}, {'priority': 2}),
          isFalse);
      expect(plannedFieldsAlreadyReduced({'clarified': true},
          {'clarified': false}), isFalse);
      // `1` and `true` encode differently, so a boolean written as an int is a
      // real difference rather than a silent match.
      expect(
        plannedFieldsAlreadyReduced({'clarified': true}, {'clarified': 1}),
        isFalse,
      );
    });
  });

  group('runInitialUpload', () {
    late SimWorkspace workspace;
    late SimDevice device;
    late SyncClient preferencesClient;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      device = workspace.a;
      preferencesClient = await device.preferencesClient;
      // Production's clients are headless until the Phase-3 flip.
      device.client.projector = null;
      preferencesClient.projector = null;
    });

    tearDown(() async => workspace.close());

    InitialUploadPlan planOf(List<PlannedEntity> entities) => InitialUploadPlan(
          entities: entities,
          resolutions: const [],
          anomalies: const [],
          legacyRowCountByTable: const {},
          excludedRowIdsByTable: const {},
          endorsedEntityIdsByCollection: const {},
        );

    Future<InitialUploadReport> upload(
      InitialUploadPlan plan, {
      int flushEveryOpCount = initialUploadFlushEveryOpCount,
      int progressEveryEntityCount = initialUploadProgressEveryEntityCount,
      void Function(InitialUploadProgress)? onProgress,
    }) =>
        runInitialUpload(
          plan: plan,
          gtdClient: device.client,
          preferencesClient: preferencesClient,
          readReducedCollection: (collection) =>
              device.registry.register(collection).readAll(),
          flushEveryOpCount: flushEveryOpCount,
          progressEveryEntityCount: progressEveryEntityCount,
          onProgress: onProgress,
        );

    PlannedEntity tag(String label, {String name = 'Home'}) => PlannedEntity(
          workspace: InitialUploadWorkspace.gtd,
          collection: tagsCollection,
          entityId: _id(label),
          fields: {
            'name': name,
            'type': 'label',
            'color': null,
            'user_id': device.userId,
          },
          legacyRowIds: [_id(label)],
        );

    test('skips an entity whose planned fields the spine already holds',
        () async {
      final plan = planOf([tag('tag/one')]);
      final first = await upload(plan);
      expect(first.authoredOpCount, 1);
      expect(first.skippedEntityCount, 0);

      final second = await upload(plan);
      expect(second.authoredOpCount, 0);
      expect(second.skippedEntityCount, 1);
      expect(second.reassertedEntityCount, 0);
    });

    test('re-asserts an entity whose planned fields changed', () async {
      await upload(planOf([tag('tag/one')]));
      final changed = await upload(
        planOf([tag('tag/one', name: 'Home renamed')]),
      );
      expect(changed.authoredOpCount, 1);
      expect(changed.reassertedEntityCount, 1);
      expect(changed.skippedEntityCount, 0);
      final reduced = await device.registry
          .register(tagsCollection)
          .readEntity(_id('tag/one'));
      expect(reduced!['name'], 'Home renamed');
    });

    test('flushes on the cadence rather than only at the tail', () async {
      final plan = planOf([
        for (var index = 0; index < 5; index++) tag('tag/batch-$index'),
      ]);
      // The property the cadence exists for is that an interruption cannot leave
      // more than the cadence un-posted — so the observation has to be *during*
      // the walk. After it, a tail-only flush is indistinguishable from a
      // cadenced one, which is why the counts are sampled from `onProgress`
      // (one emission per entity here) rather than at the end.
      final storedOpCountsDuringWalk = <int>[];
      final report = await upload(
        plan,
        flushEveryOpCount: 2,
        progressEveryEntityCount: 1,
        onProgress: (_) =>
            storedOpCountsDuringWalk.add(workspace.server.storedOps.length),
      );
      expect(report.authoredOpCount, 5);
      // Ops reached the server before the walk ended, and not all of them: the
      // tail flush is neither what put them there nor what posted every one.
      expect(storedOpCountsDuringWalk.first,
          lessThan(storedOpCountsDuringWalk.last));
      expect(storedOpCountsDuringWalk.last,
          lessThan(workspace.server.storedOps.length));
      expect((await device.client.health()).pendingOpCount, 0);
    });

    test('progress counters advance inside the walk, not once per collection',
        () async {
      final plan = planOf([
        for (var index = 0; index < 4; index++) tag('tag/progress-$index'),
      ]);
      final completedCounts = <int>[];
      await upload(
        plan,
        progressEveryEntityCount: 1,
        onProgress: (progress) =>
            completedCounts.add(progress.completedEntityCount),
      );
      // The head-of-collection emission and then one per entity. Without the
      // in-walk emission this is `[0]` and the screen's line never moves.
      expect(completedCounts, [0, 1, 2, 3, 4]);
    });

    test('a preference value with no key is refused at the call site',
        () async {
      // ADR-0033's guard, at the author's own site (#573): the payload never
      // reaches the outbox, the run continues, and the entity is named. Without
      // the guard this op would be quarantined by every peer *and* by this
      // device's own echo.
      final plan = planOf([
        PlannedEntity(
          workspace: InitialUploadWorkspace.preferences,
          collection: userPreferencesCollection,
          entityId: preferenceEntityId(
            preferencesClient.workspaceId,
            'clarify_mode',
          ),
          fields: {
            preferenceValueField: '"oneToOne"',
            'user_id': device.userId,
            'updated_at': '2026-07-01T07:00:00.000Z',
          },
          legacyRowIds: const [],
        ),
      ]);
      final report = await upload(plan);
      expect(report.refusedEntityCount, 1);
      expect(report.authoredOpCount, 0);
      expect(report.anomalies.single.kind, uploadRefused);
      expect(report.anomalies.single.raw,
          contains('preference_value_without_key'));
      // Nothing was authored, so nothing is queued either.
      expect((await preferencesClient.health()).pendingOpCount, 0);
    });

    test('routes preferences into the preferences Workspace', () async {
      final entityId = preferenceEntityId(
        preferencesClient.workspaceId,
        'clarify_mode',
      );
      final report = await upload(planOf([
        PlannedEntity(
          workspace: InitialUploadWorkspace.preferences,
          collection: userPreferencesCollection,
          entityId: entityId,
          fields: {
            preferenceKeyField: 'clarify_mode',
            preferenceValueField: '"oneToOne"',
            'user_id': device.userId,
            'updated_at': '2026-07-01T07:00:00.000Z',
          },
          legacyRowIds: const [],
        ),
      ]));
      expect(report.authoredOpCount, 1);
      // The GTD Workspace's log holds no content op; the preferences one does.
      expect((await device.client.health()).pendingOpCount, 0);
      final stored = workspace.server.storedOps
          .where((op) => op.workspaceId == preferencesClient.workspaceId)
          .length;
      expect(stored, greaterThan(0));
    });
  });
}
