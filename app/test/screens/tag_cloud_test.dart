import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/screens/common/tag_management_sheet.dart';
import 'package:jeeves/widgets/tag_text.dart';

import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/focus_session_planning_settings_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/models/focus_session_planning_settings.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/screens/app_shell.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import '../test_helpers.dart';

// ---------------------------------------------------------------------------
// Mock notifiers
// ---------------------------------------------------------------------------

class _MockAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;
  @override
  Future<void> logout() async {}
}

class _MockFocusSessionPlanningNotifier extends FocusSessionPlanningNotifier {
  @override
  Future<void> reEnterPlanning() async {}
}

/// Disables the planning banner so its infinite pulse animation doesn't
/// prevent [WidgetTester.pumpAndSettle] from completing.
class _NoBannerSettingsNotifier extends FocusSessionPlanningSettingsNotifier {
  @override
  FocusSessionPlanningSettings build() =>
      const FocusSessionPlanningSettings(bannerEnabled: false);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Tag _tag(String id, String name) =>
    Tag(id: id, name: name, type: 'context', userId: 'u1');

TagWithCount _twc(Tag tag, int count) =>
    TagWithCount(tag: tag, count: count);

Widget _buildShell({
  List<TagWithCount> contextTagsWithCount = const [],
  List<Tag> contextTags = const [],
}) {
  return ProviderScope(
    overrides: [
      authTokenProvider.overrideWith(() => _MockAuthNotifier()),
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
      nextProvider.overrideWith((_) => Stream.value([])),
      waitingForProvider.overrideWith((_) => Stream.value([])),
      somedayMaybeProvider.overrideWith((_) => Stream.value([])),
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider
          .overrideWith((_) => Stream.value(contextTags)),
      contextTagsWithCountProvider
          .overrideWith((_) => Stream.value(contextTagsWithCount)),
      focusSessionPlanningSelectedTasksProvider.overrideWith((_) => Stream.value([])),
      focusSessionPlanningProvider.overrideWith(() => _MockFocusSessionPlanningNotifier()),
      focusSessionPlanningSettingsProvider
          .overrideWith(() => _NoBannerSettingsNotifier()),
      // Suppress the Weekly Review banner so its pulse animation doesn't
      // leave a Timer pending when the test tears down.
      periodicReviewBannerEnabledProvider.overrideWith((_) => false),
      // The Nudge queue would otherwise reach into the Trigger chain and
      // construct a second GtdDatabase via the un-overridden databaseProvider;
      // force the queue empty so AppShell's NudgeBanner stays hidden.
      nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
    ],
    child: MaterialApp(
      home: Builder(builder: (ctx) {
        final router = GoRouter(
          initialLocation: '/inbox',
          routes: [
            ShellRoute(
              builder: (context, state, child) => AppShell(child: child),
              routes: [
                GoRoute(
                  path: '/inbox',
                  builder: (_, _) => Scaffold(
                    body: Builder(
                      builder: (innerCtx) => IconButton(
                        icon: const Icon(Icons.menu),
                        onPressed: () => innerCtx
                            .findRootAncestorStateOfType<ScaffoldState>()
                            ?.openDrawer(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
        return MaterialApp.router(routerConfig: router);
      }),
    ),
  );
}

Future<void> _openDrawer(WidgetTester tester) async {
  // The drawer opens from the shared title bar's leading (drawer) slot.
  await tester.tap(find.byKey(appTitleBarLeadingKey));
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(configureSqliteForTests);

  group('TagCloud in drawer', () {
    testWidgets('renders no chips when tag list is empty', (tester) async {
      await tester.pumpWidget(_buildShell());
      await tester.pump();
      await _openDrawer(tester);

      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsNothing);
    });

    testWidgets('renders tags for tags with active tasks', (tester) async {
      final tag = _tag('ctx1', 'Work');
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: [_twc(tag, 3)],
        contextTags: [tag],
      ));
      await tester.pump();
      await _openDrawer(tester);

      expect(find.byKey(const Key('tag_chip_ctx1')), findsOneWidget);
      expect(find.byType(TagText), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('clear filters button deselects all tags', (tester) async {
      final tag = _tag('ctx1', 'Work');
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: [_twc(tag, 2)],
        contextTags: [tag],
      ));
      await tester.pump();
      await _openDrawer(tester);

      // Select tag
      await tester.ensureVisible(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('tag_cloud_clear_filters')), findsOneWidget);

      // Clear
      await tester.tap(find.byKey(const Key('tag_cloud_clear_filters')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('tag_cloud_clear_filters')), findsNothing);
    });
  });

  group('TagCloud organisation', () {
    // 20 tags with distinct counts (t00 busiest), staged in the DAO's
    // name order to prove the widget re-orders by usage itself.
    List<TagWithCount> twenty() => [
          for (var i = 0; i < 20; i++)
            _twc(_tag('t$i', 'tag${i.toString().padLeft(2, '0')}'), 20 - i),
        ]..sort((a, b) => a.tag.name.compareTo(b.tag.name));

    testWidgets('collapses to 12 with a toggle that expands and collapses',
        (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      expect(find.byType(TagText), findsNWidgets(12));
      expect(find.text('Show 8 more'), findsOneWidget);
      expect(find.byKey(const Key('tag_chip_t19')), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      expect(find.byType(TagText, skipOffstage: false), findsNWidgets(20));
      expect(find.text('Show fewer'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      expect(find.byType(TagText), findsNWidgets(12));
    });

    testWidgets('find field and toggle are absent at or under the cap',
        (tester) async {
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: twenty().take(12).toList(),
      ));
      await tester.pump();
      await _openDrawer(tester);

      expect(find.byKey(const Key('tag_cloud_find_field')), findsNothing);
      expect(find.byKey(const Key('tag_cloud_show_more')), findsNothing);
    });

    testWidgets(
        'find journey: narrow, tap, pinned first, field survives few matches',
        (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), '@TAG19');
      await tester.pumpAndSettle();
      // One match (< 12) — the field must still be there.
      expect(find.byKey(const Key('tag_cloud_find_field')), findsOneWidget);
      expect(find.byType(TagText), findsOneWidget);
      expect(find.byKey(const Key('tag_chip_t19')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tag_chip_t19')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tag_cloud_find_clear')));
      await tester.pumpAndSettle();
      // Selected low-count tag is now pinned among the 12 visible.
      expect(find.byKey(const Key('tag_chip_t19')), findsOneWidget);
      expect(find.byType(TagText), findsNWidgets(12));
      final firstChip = tester.widget<TagText>(find.byType(TagText).first);
      expect(firstChip.tag.id, 't19');

      await tester.tap(find.byKey(const Key('tag_cloud_clear_filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsNothing);
    });

    testWidgets('shows No matches for an unmatched query', (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_cloud_no_matches')), findsOneWidget);
    });

    testWidgets('applies size steps by relative count', (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      TagText chip(String id) =>
          tester.widget<TagText>(find.byKey(Key('tag_chip_$id')));
      expect(chip('t0').fontSize, 15);
      expect(chip('t11').fontSize, 13);

      await tester.ensureVisible(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      expect(chip('t19').fontSize, 12);
    });

    testWidgets('long-press opens tag management', (tester) async {
      final tags = twenty();
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: tags,
        contextTags: [for (final t in tags) t.tag],
      ));
      await tester.pump();
      await _openDrawer(tester);

      await tester.longPress(find.byKey(const Key('tag_chip_t0')));
      await tester.pumpAndSettle();
      expect(find.byType(TagManagementSheet), findsOneWidget);
    });
  });

  group('TagCloud drawer close', () {
    List<TagWithCount> twenty() => [
          for (var i = 0; i < 20; i++)
            _twc(_tag('t$i', 'tag${i.toString().padLeft(2, '0')}'), 20 - i),
        ];

    testWidgets('closing and reopening the drawer resets query and expansion',
        (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      await tester.ensureVisible(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_cloud_show_more')));
      await tester.pumpAndSettle();
      expect(find.text('Show fewer'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), 'tag1');
      await tester.pumpAndSettle();
      expect(find.byType(TagText), findsNWidgets(10));

      // Close by tapping the scrim, then reopen.
      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle();
      await _openDrawer(tester);

      final field = tester.widget<TextField>(
          find.byKey(const Key('tag_cloud_find_field')));
      expect(field.controller?.text, isEmpty);
      expect(find.text('Show 8 more'), findsOneWidget);
      expect(find.byType(TagText), findsNWidgets(12));
    });

    testWidgets('a query typed while collapsed is cleared on reopen',
        (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: twenty()));
      await tester.pump();
      await _openDrawer(tester);

      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), 'tag19');
      await tester.pumpAndSettle();
      expect(find.byType(TagText), findsNWidgets(1));

      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle();
      await _openDrawer(tester);

      final field = tester.widget<TextField>(
          find.byKey(const Key('tag_cloud_find_field')));
      expect(field.controller?.text, isEmpty);
      expect(find.byType(TagText), findsNWidgets(12));
    });
  });

  group('TagCloud journey over a real database', () {
    late GtdDatabase db;
    late List<TagWithCount> counted;

    setUp(() async {
      db = GtdDatabase(NativeDatabase.memory());
      const userId = 'u1';
      final now = DateTime.now();
      for (var k = 0; k < 20; k++) {
        await db.into(db.todos).insert(TodosCompanion(
              id: Value('todo$k'),
              title: Value('todo $k'),
              userId: const Value(userId),
              createdAt: Value(now),
              updatedAt: Value(now),
            ));
      }
      for (var i = 0; i < 20; i++) {
        final id = 't$i';
        await db.tagDao.upsertTag(TagsCompanion(
          id: Value(id),
          name: Value('tag${i.toString().padLeft(2, '0')}'),
          type: const Value('context'),
          userId: const Value(userId),
        ));
        // Tag i is on 20 - i todos, so tag19 is the least used (1).
        for (var k = 0; k < 20 - i; k++) {
          await db.tagDao.assignTag('todo$k', id, userId);
        }
      }
      // Staged here, outside FakeAsync: a live drift watch inside the widget
      // test would hang (docs/TESTING.md).
      counted = await db.tagDao.watchTagsWithActiveCount('context').first;
    });

    tearDown(() async => db.close());

    testWidgets('cap, find, select, pin, clear', (tester) async {
      await tester.pumpWidget(_buildShell(contextTagsWithCount: counted));
      await tester.pump();
      await _openDrawer(tester);

      expect(find.byType(TagText), findsNWidgets(12));
      expect(find.text('Show 8 more'), findsOneWidget);
      expect(find.byKey(const Key('tag_chip_t19')), findsNothing);

      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), 'tag19');
      await tester.pumpAndSettle();
      expect(find.byType(TagText), findsOneWidget);
      expect(find.byKey(const Key('tag_chip_t19')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tag_chip_t19')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('tag_cloud_find_field')), '');
      await tester.pumpAndSettle();
      // Selected tag is pinned first although its count is the lowest.
      final firstTag = tester.widget<TagText>(find.byType(TagText).first);
      expect(firstTag.tag.name, 'tag19');

      await tester.tap(find.byKey(const Key('tag_cloud_clear_filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsNothing);
    });
  });

  group('Active filter bar in list views', () {
    testWidgets('filter strip is hidden when no filter is active',
        (tester) async {
      final tag = _tag('ctx1', 'Work');
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: [_twc(tag, 2)],
        contextTags: [tag],
      ));
      await tester.pump();

      // No filter bar chips visible when filter is empty
      expect(find.byKey(const Key('active_filter_chip_ctx1')), findsNothing);
    });

    testWidgets(
        'selecting a tag updates tagFilterProvider and shows the clear button',
        (tester) async {
      final tag = _tag('ctx1', 'Work');
      late WidgetRef capturedRef;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authTokenProvider.overrideWith(() => _MockAuthNotifier()),
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          nextProvider.overrideWith((_) => Stream.value([])),
          waitingForProvider.overrideWith((_) => Stream.value([])),
              somedayMaybeProvider.overrideWith((_) => Stream.value([])),
          projectTagsProvider.overrideWith((_) => Stream.value([])),
          contextTagsProvider.overrideWith((_) => Stream.value([tag])),
          contextTagsWithCountProvider
              .overrideWith((_) => Stream.value([_twc(tag, 2)])),
          focusSessionPlanningSelectedTasksProvider.overrideWith((_) => Stream.value([])),
          focusSessionPlanningProvider
              .overrideWith(() => _MockFocusSessionPlanningNotifier()),
          focusSessionPlanningSettingsProvider
              .overrideWith(() => _NoBannerSettingsNotifier()),
          periodicReviewBannerEnabledProvider.overrideWith((_) => false),
          nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          capturedRef = ref;
          final router = GoRouter(
            initialLocation: '/inbox',
            routes: [
              ShellRoute(
                builder: (context, state, child) =>
                    AppShell(child: child),
                routes: [
                  GoRoute(
                    path: '/inbox',
                    builder: (_, _) => Scaffold(
                      body: Builder(
                        builder: (innerCtx) => IconButton(
                          icon: const Icon(Icons.menu),
                          onPressed: () => innerCtx
                              .findRootAncestorStateOfType<ScaffoldState>()
                              ?.openDrawer(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
          return MaterialApp.router(routerConfig: router);
        }),
      ));
      await tester.pump();
      await _openDrawer(tester);

      expect(capturedRef.read(tagFilterProvider), isEmpty);

      await tester.ensureVisible(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();

      expect(capturedRef.read(tagFilterProvider), contains('ctx1'));
      // Selecting a tag also surfaces the clear-filters affordance.
      expect(find.byKey(const Key('tag_cloud_clear_filters')), findsOneWidget);
    });
  });
}
