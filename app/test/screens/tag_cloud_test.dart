import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/widgets/tag_text.dart';

import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/connectivity_provider.dart';
import 'package:jeeves/providers/daily_planning_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/planning_settings_provider.dart';
import 'package:jeeves/providers/tag_filter_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/database/gtd_database.dart' show Tag;
import 'package:jeeves/models/planning_settings.dart';
import 'package:jeeves/screens/app_shell.dart';
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

class _MockDailyPlanningNotifier extends DailyPlanningNotifier {
  @override
  Future<void> reEnterPlanning() async {}
}

/// Disables the planning banner so its infinite pulse animation doesn't
/// prevent [WidgetTester.pumpAndSettle] from completing.
class _NoBannerSettingsNotifier extends PlanningSettingsNotifier {
  @override
  PlanningSettings build() => const PlanningSettings(bannerEnabled: false);
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
      isOnlineProvider.overrideWith((_) => Stream.value(true)),
      inboxItemsProvider.overrideWith((_) => Stream.value([])),
      nextActionsProvider.overrideWith((_) => Stream.value([])),
      waitingForProvider.overrideWith((_) => Stream.value([])),
      blockedTasksProvider.overrideWith((_) => Stream.value([])),
      somedayMaybeProvider.overrideWith((_) => Stream.value([])),
      scheduledProvider.overrideWith((_) => Stream.value([])),
      projectTagsProvider.overrideWith((_) => Stream.value([])),
      contextTagsProvider
          .overrideWith((_) => Stream.value(contextTags)),
      contextTagsWithCountProvider
          .overrideWith((_) => Stream.value(contextTagsWithCount)),
      todaySelectedTasksProvider.overrideWith((_) => Stream.value([])),
      dailyPlanningProvider.overrideWith(() => _MockDailyPlanningNotifier()),
      planningSettingsProvider
          .overrideWith(() => _NoBannerSettingsNotifier()),
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
  await tester.tap(find.byIcon(Icons.menu));
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

    testWidgets('tapping a chip selects it and shows clear button',
        (tester) async {
      final tag = _tag('ctx1', 'Work');
      await tester.pumpWidget(_buildShell(
        contextTagsWithCount: [_twc(tag, 2)],
        contextTags: [tag],
      ));
      await tester.pump();
      await _openDrawer(tester);

      await tester.ensureVisible(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag_chip_ctx1')));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const Key('tag_cloud_clear_filters')), findsOneWidget);
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

    testWidgets('selecting a tag updates tagFilterProvider state', (tester) async {
      final tag = _tag('ctx1', 'Work');
      late WidgetRef capturedRef;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authTokenProvider.overrideWith(() => _MockAuthNotifier()),
          isOnlineProvider.overrideWith((_) => Stream.value(true)),
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          nextActionsProvider.overrideWith((_) => Stream.value([])),
          waitingForProvider.overrideWith((_) => Stream.value([])),
          blockedTasksProvider.overrideWith((_) => Stream.value([])),
          somedayMaybeProvider.overrideWith((_) => Stream.value([])),
          scheduledProvider.overrideWith((_) => Stream.value([])),
          projectTagsProvider.overrideWith((_) => Stream.value([])),
          contextTagsProvider.overrideWith((_) => Stream.value([tag])),
          contextTagsWithCountProvider
              .overrideWith((_) => Stream.value([_twc(tag, 2)])),
          todaySelectedTasksProvider.overrideWith((_) => Stream.value([])),
          dailyPlanningProvider
              .overrideWith(() => _MockDailyPlanningNotifier()),
          planningSettingsProvider
              .overrideWith(() => _NoBannerSettingsNotifier()),
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
    });
  });
}
