/// The journey: a real fault happens, the indicator tells the truth about it,
/// and the screen behind it says what happened in the user's own words.
///
/// **The faults are real and so is everything that reads them.** Each group runs
/// a hostile server against a real `SimWorkspace` — a forged envelope, a withheld
/// op, a key that never arrived — and then feeds the widgets what the production
/// code makes of the resulting store: the real health SQL through the real
/// `syncIndicationFor`, and the real rows through the real
/// `syncHealthConditionsFor`. Nothing about the classification, the counts, the
/// copy or the grouping is staged.
///
/// Two harness rules this file obeys, both of which cost a ten-minute hang to
/// learn (docs/TESTING.md):
///
/// * **The staging happens in `setUp`, never inside a `testWidgets` body.** A
///   widget test body runs under `FakeAsync`, so a real `NativeDatabase` round
///   trip inside one never completes and the test sits until the harness times
///   it out. Where a body genuinely has to touch the store, it does so through
///   `tester.runAsync`.
/// * **The two providers' subscription plumbing is substituted**, and only
///   because a live Drift `watch()` under a widget test never settles. Each
///   override is a `Stream.value` over data read out of a real store a moment
///   earlier, so the widget sees exactly what the provider would have handed it.
@TestOn('!browser')
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/sync_health_detail_provider.dart';
import 'package:jeeves/providers/sync_status_provider.dart';
import 'package:jeeves/screens/sync_health/sync_health_copy.dart';
import 'package:jeeves/screens/sync_health/sync_health_screen.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/enrolment_state.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_health.dart';
import 'package:jeeves/sync/sync_health_detail.dart';

import '../../sync/harness/sim_device.dart';
import '../../sync/harness/sim_workspace.dart';

const String _collection = 'harness_docs';
const String _entityId = '5f2a9c3e-8d41-4b7a-9e26-0c1d3f5b7a92';

extension _Author on SimDevice {
  Future<void> authorLocal(String value) => client.capture(
        collection: _collection,
        entityId: _entityId,
        fields: {'step': value},
      );
}

/// Everything the two surfaces read, taken out of one real device.
typedef DeviceReport = ({
  SyncIndication indication,
  List<SyncHealthCondition> conditions,
});

Future<DeviceReport> _reportFor(
  SimDevice device, {
  List<SyncClient> extraClients = const [],
}) async {
  final clients = [device.client, ...extraClients];
  final health = <SyncHealth>[];
  final conditions = <SyncHealthCondition>[];
  for (final client in clients) {
    health.add(await client.health());
    conditions.addAll(syncHealthConditionsFor(
      workspaceId: client.workspaceId,
      alarms: await client.integrityAlarms(),
      refusals: await client.quarantined(),
    ));
  }
  return (
    indication: syncIndicationFor(
      enrolment: EnrolmentState.enrolled,
      hasMemberCredential: true,
      health: health,
    ),
    conditions: conditions,
  );
}

/// A device whose own op came back tampered with: the signature covers
/// `header || body`, so the receive path refuses it outright — the fail-closed
/// rule doing precisely its job, and a condition the app handled perfectly.
Future<void> _plantForgedEnvelope(SimWorkspace workspace) async {
  final a = workspace.a;
  await a.authorLocal('mine');
  await a.sync();
  final authored = await a.client.authoredEnvelopes();
  final tampered = Uint8List.fromList(authored.last);
  tampered[headerLengthBytes + 8] ^= 0x01;
  workspace.server.injectUnchecked(workspace.workspaceId, tampered);
  await a.sync();
}

class _SignedInAs extends CurrentUserIdNotifier {
  _SignedInAs(this.userId);
  final String userId;

  @override
  String build() => userId;
}

/// The screen, over one device's real report.
Widget _screenOver(DeviceReport report, {required String userId}) => ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith(() => _SignedInAs(userId)),
        syncHealthDetailProvider.overrideWith((_) => Stream.value(report.conditions)),
      ],
      child: const MaterialApp(home: SyncHealthScreen()),
    );

/// Just the drawer indicator, mounted the way the shell mounts it — enough to
/// assert the glyph, the tone, the tooltip and whether a tap goes anywhere.
Widget _indicatorOver(DeviceReport report) {
  final router = GoRouter(
    initialLocation: '/inbox',
    routes: [
      GoRoute(
        path: '/inbox',
        builder: (_, _) => Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                _IndicatorHarness(indication: ref.watch(syncStatusProvider).value),
          ),
        ),
      ),
      GoRoute(
        path: SyncHealthScreen.routePath,
        builder: (_, _) => const Scaffold(body: Text('the sync health screen')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      syncStatusProvider.overrideWith((_) => Stream.value(report.indication)),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// A stand-in for the drawer header's slot: the production `_SyncIndicator` is
/// private, so this asserts the same contract against the same values — the
/// tuple the shell renders, and the tap the shell wires.
class _IndicatorHarness extends StatelessWidget {
  const _IndicatorHarness({required this.indication});
  final SyncIndication? indication;

  @override
  Widget build(BuildContext context) {
    final (icon, color, tooltip) = switch (indication?.status) {
      SyncStatus.localOnly => (Icons.cloud_off_outlined, const Color(0xFF9CA3AF), 'Local only'),
      SyncStatus.connecting => (Icons.cloud_upload_outlined, const Color(0xFF9CA3AF), 'Connecting'),
      SyncStatus.syncing => (Icons.cloud_sync, const Color(0xFF2563EB), 'Syncing'),
      SyncStatus.synced => (Icons.cloud_done, const Color(0xFF16A34A), 'Synced'),
      SyncStatus.worthKnowing => (
          Icons.cloud_done_outlined,
          const Color(0xFFF59E0B),
          syncHealthWorthKnowingTooltip,
        ),
      SyncStatus.error => (Icons.cloud_off, const Color(0xFFDC2626), 'Sync error'),
      null => (Icons.cloud_off_outlined, const Color(0xFF9CA3AF), 'Local only'),
    };
    final glyph = Tooltip(message: tooltip, child: Icon(icon, size: 20, color: color));
    if (indication?.hasSomethingToReport != true) return glyph;
    return InkWell(
      onTap: () => context.push(SyncHealthScreen.routePath),
      child: Padding(padding: const EdgeInsets.all(8), child: glyph),
    );
  }
}

/// Every string the screen actually rendered, off-stage children excluded — the
/// collapsed screen is the thing under test.
List<String> _renderedText(WidgetTester tester) => [
      for (final element in find.byType(Text).evaluate())
        (element.widget as Text).data ??
            (element.widget as Text).textSpan?.toPlainText() ??
            '',
    ];

void main() {
  group('E1 a handled condition is not an error, and is readable', () {
    late SimWorkspace workspace;
    late DeviceReport report;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      await _plantForgedEnvelope(workspace);
      report = await _reportFor(workspace.a);
    });

    tearDown(() async => workspace.close());

    testWidgets('the indicator is calm, not red, and is tappable', (tester) async {
      // FAILS ON MAIN: the same store paints the indicator permanently red.
      expect(report.indication.status, SyncStatus.worthKnowing);
      expect(report.indication.hasSomethingToReport, isTrue);

      await tester.pumpWidget(_indicatorOver(report));
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, Icons.cloud_done_outlined,
          reason: 'the shape differs from healthy, so the state survives a '
              'colour-blind reading');
      expect(icon.color, const Color(0xFFF59E0B));
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        syncHealthWorthKnowingTooltip,
      );

      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.text('the sync health screen'), findsOneWidget);
    });

    testWidgets('the screen says what happened, in plain words', (tester) async {
      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      expect(
        find.text(sentenceForAlarmCode(IntegrityAlarmKind.signatureInvalid.code)),
        findsWidgets,
        reason: 'the refused item and the accusation it raised are the same '
            'event, so both rows say the same true thing',
      );
      expect(find.text(syncHealthHandledHeading), findsOneWidget);
      expect(
        find.text(syncHealthNeedsAttentionHeading),
        findsNothing,
        reason: "nothing of the user's is stuck",
      );
      expect(find.text(syncHealthAllHandledExplanation), findsOneWidget);
    });

    testWidgets('no machine vocabulary reaches the collapsed screen', (tester) async {
      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      final rendered = _renderedText(tester);
      expect(rendered, isNotEmpty);
      for (final text in rendered) {
        for (final word in syncHealthBannedWords) {
          expect(
            RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false).hasMatch(text),
            isFalse,
            reason: 'the screen said "$word": $text',
          );
        }
        for (final phrase in syncHealthBannedDeviceReferences) {
          expect(
            text.toLowerCase().contains(phrase),
            isFalse,
            reason: 'the screen pointed at an unnamed device: $text',
          );
        }
        expect(
          RegExp(r'\b[a-z]+_[a-z_]+\b').hasMatch(text),
          isFalse,
          reason: 'a raw code reached the collapsed screen: $text',
        );
      }
      // The code, the row id and the engine's own detail live behind the
      // expander and nowhere else (#584 AC-4).
      expect(find.text(IntegrityAlarmKind.signatureInvalid.code), findsNothing);
    });

    testWidgets('nothing on the screen is pressable, and nothing is dismissed',
        (tester) async {
      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.textContaining('Dismiss'), findsNothing);
      expect(find.textContaining('Retry'), findsNothing);
    });

    testWidgets('visiting the screen changes nothing in the store', (tester) async {
      final before = await tester.runAsync(() async => (
            refusals: (await workspace.a.client.quarantined()).length,
            alarms: (await workspace.a.client.integrityAlarms()).length,
            envelopes: await workspace.a.client.authoredEnvelopes(),
          ));

      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      final after = await tester.runAsync(() async => (
            refusals: (await workspace.a.client.quarantined()).length,
            alarms: (await workspace.a.client.integrityAlarms()).length,
            envelopes: await workspace.a.client.authoredEnvelopes(),
          ));
      expect(after!.refusals, before!.refusals);
      expect(after.alarms, before.alarms);
      expect(after.envelopes, before.envelopes);
    });
  });

  group('E1b a withheld op is an error, and is named as one', () {
    late SimWorkspace workspace;
    late DeviceReport report;

    setUp(() async {
      workspace = await SimWorkspace.create();
      await workspace.syncAll();
      final b = workspace.b;
      await b.authorLocal('one');
      await b.authorLocal('two');
      await b.sync();
      // The server simply stops serving the first of B's two content ops, so
      // the second lands beyond the verified head. Withholding is detectable,
      // not preventable, and no later sync conjures it back.
      final peerContent = [
        for (final op in workspace.server.storedOps)
          if (op.workspaceId == workspace.workspaceId &&
              op.header?.opClass == opClassContent &&
              op.header?.authorMemberId == b.identity.memberId)
            op.seq,
      ]..sort();
      workspace.server.omitSeqs.add(peerContent.first);
      await workspace.a.sync();
      report = await _reportFor(workspace.a);
    });

    tearDown(() async => workspace.close());

    testWidgets('the gap sits under Needs attention, and the calm sentence is gone',
        (tester) async {
      expect(report.indication.status, SyncStatus.error);

      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      expect(find.text(syncHealthNeedsAttentionHeading), findsOneWidget);
      expect(
        find.text(sentenceForAlarmCode(IntegrityAlarmKind.authorChainGap.code)),
        findsWidgets,
      );
      expect(
        find.text(syncHealthAllHandledExplanation),
        findsNothing,
        reason: 'something does need the user, so the all-clear must not show',
      );
    });
  });

  group('E2 a clean device has no entry point', () {
    late SimWorkspace workspace;
    late DeviceReport report;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      await workspace.a.authorLocal('nothing wrong here');
      await workspace.a.sync();
      report = await _reportFor(workspace.a);
    });

    tearDown(() async => workspace.close());

    testWidgets('the tile is not tappable, and the glyph is healthy', (tester) async {
      expect(report.indication.status, SyncStatus.synced);
      expect(report.indication.hasSomethingToReport, isFalse);
      expect(report.conditions, isEmpty);

      await tester.pumpWidget(_indicatorOver(report));
      await tester.pumpAndSettle();
      expect(
        find.byType(InkWell),
        findsNothing,
        reason: 'a device with nothing to report offers no way in',
      );
      expect(tester.widget<Icon>(find.byType(Icon)).icon, Icons.cloud_done);
    });

    testWidgets('deep-linking it anyway shows an empty account, not a blank page',
        (tester) async {
      // A route is reachable by more than a tap, so the screen must survive
      // being opened with nothing to say.
      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      expect(find.text(syncHealthAllHandledExplanation), findsOneWidget);
      expect(find.text(syncHealthNeedsAttentionHeading), findsNothing);
      expect(find.text(syncHealthHandledHeading), findsNothing);
    });
  });

  group('E2b a device waiting on a key has no entry point either', () {
    late SimWorkspace workspace;
    late DeviceReport report;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 2);
      final a = workspace.a;
      final b = workspace.b;
      await a.enrolment.turnOnEncryption(passphrase: workspace.passphrase);
      await workspace.syncAll();
      // A rotation B holds no wrap for: revoked, and served anyway by a hostile
      // server. A live member re-fetches its wrap on the pull tail and heals
      // itself, which is the whole reason this condition is self-healing.
      await a.enrolment.revokeAndRotate(
        passphrase: workspace.passphrase,
        memberId: b.identity.memberId,
      );
      await a.authorLocal('after the rotation');
      await a.sync();
      workspace.server.poisonGrantLiveness(
        workspace.workspaceId,
        workspace.ownerGrantIdOf(b.identity.memberId),
      );
      await b.client.sync();
      report = await _reportFor(b);
    });

    tearDown(() async => workspace.close());

    testWidgets('not an error, and nothing to read', (tester) async {
      // FAILS ON MAIN on both counts: today this is a permanent red icon for a
      // condition that heals itself and that the user cannot act on.
      expect(report.indication.status, SyncStatus.synced);
      expect(report.indication.hasSomethingToReport, isFalse);
      expect(report.conditions, isEmpty);

      await tester.pumpWidget(_indicatorOver(report));
      await tester.pumpAndSettle();
      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('E5 both Workspaces are present and attributed', () {
    late SimWorkspace workspace;
    late DeviceReport report;

    setUp(() async {
      workspace = await SimWorkspace.create(deviceCount: 1);
      await _plantForgedEnvelope(workspace);
      report = await _reportFor(
        workspace.a,
        extraClients: [await workspace.a.preferencesClient],
      );
    });

    tearDown(() async => workspace.close());

    testWidgets('the section is labelled in the user\'s terms, never by id',
        (tester) async {
      await tester.pumpWidget(_screenOver(report, userId: workspace.userId));
      await tester.pumpAndSettle();

      expect(
        find.text(syncWorkspaceLabelFor(workspace.workspaceId, workspace.userId)!),
        findsOneWidget,
      );
      expect(find.textContaining(workspace.workspaceId), findsNothing);
    });

    test('every id this build knows has an honest label, and no other does', () {
      expect(
        syncWorkspaceLabelFor(defaultWorkspaceId('sim-user'), 'sim-user'),
        'TASKS AND LISTS',
      );
      expect(
        syncWorkspaceLabelFor(userPreferencesWorkspaceId('sim-user'), 'sim-user'),
        'SETTINGS',
      );
      expect(syncWorkspaceLabelFor('not-a-workspace-of-ours', 'sim-user'), isNull);
    });
  });
}
