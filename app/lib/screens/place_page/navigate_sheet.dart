/// The sheet that hands an errand to Google Maps or Waze (issue #60).
///
/// Jeeves plans no route. The chosen stops go to the map app in the order the
/// place page shows them, and the app does the routing. Only coordinates are
/// sent, and only when the user taps a route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/errand_route.dart';
import '../../providers/navigation_app_opener_provider.dart';
import '../../services/navigation_app_opener.dart';

/// Opens the sheet for the stops of an errand, one list per nearby group.
Future<void> showNavigateSheet(
  BuildContext context,
  List<List<ErrandStop>> stopsByGroup,
) {
  final routes = errandRoutes(stopsByGroup);
  if (routes.isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NavigateSheet(routes: routes),
  );
}

class _NavigateSheet extends ConsumerStatefulWidget {
  const _NavigateSheet({required this.routes});

  /// The routes Google Maps is offered, in page order.
  final List<List<ErrandStop>> routes;

  @override
  ConsumerState<_NavigateSheet> createState() => _NavigateSheetState();
}

class _NavigateSheetState extends ConsumerState<_NavigateSheet> {
  bool _choosingRoute = false;

  int get _stopCount =>
      widget.routes.fold<int>(0, (sum, route) => sum + route.length);

  Future<void> _open(NavigationApp app, Uri uri) async {
    final sheetRoute = ModalRoute.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final opened = await ref.read(navigationAppOpenerProvider).open(app, uri);
    // Pop only while this sheet is still on top: a dismissed sheet must not
    // take the page beneath it down with it.
    if (sheetRoute?.isCurrent ?? false) navigator.pop();
    if (opened) return;
    messenger.showSnackBar(SnackBar(
      content: Text(app == NavigationApp.googleMaps
          ? 'Google Maps is not installed'
          : 'Could not open Waze'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final routes = widget.routes;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_choosingRoute) ...[
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Routes in Google Maps'),
              onTap: () => setState(() => _choosingRoute = false),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (index, route) in routes.indexed)
                    ListTile(
                      key: Key('navigate_route_$index'),
                      title: Text(
                        'Route ${index + 1} · ${_stops(route.length)}',
                      ),
                      subtitle: Text(
                        route.map((stop) => stop.label).join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _open(
                        NavigationApp.googleMaps,
                        googleMapsRouteUri(route),
                      ),
                    ),
                ],
              ),
            ),
          ] else ...[
            ListTile(
              key: const Key('navigate_google_maps'),
              leading: const Icon(Icons.map_outlined),
              title: const Text('Google Maps'),
              subtitle: Text(routes.length == 1
                  ? 'All ${_stops(_stopCount)}'
                  : '${_stops(_stopCount)} in ${routes.length} routes'),
              onTap: routes.length == 1
                  ? () => _open(
                        NavigationApp.googleMaps,
                        googleMapsRouteUri(routes.single),
                      )
                  : () => setState(() => _choosingRoute = true),
            ),
            ListTile(
              key: const Key('navigate_waze'),
              leading: const Icon(Icons.navigation_outlined),
              title: const Text('Waze'),
              subtitle: Text(
                'Next stop only: ${routes.first.first.label}',
              ),
              onTap: () => _open(NavigationApp.waze, wazeUri(routes.first.first)),
            ),
          ],
        ],
      ),
    );
  }

  String _stops(int count) => count == 1 ? '1 stop' : '$count stops';
}
