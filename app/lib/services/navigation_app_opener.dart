/// The port for opening a map app with a route (issue #60).
///
/// Jeeves hands the chosen Places to Google Maps or Waze through a link and
/// does no routing itself. The port keeps the OS out of the journeys: they
/// override it with a recording fake.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// The map apps Jeeves hands a route to.
enum NavigationApp { googleMaps, waze }

/// Opens a link in a map app.
abstract class NavigationAppOpener {
  /// Opens [uri] in [app]. Returns whether it opened.
  Future<bool> open(NavigationApp app, Uri uri);
}

/// Opens the link through the platform.
///
/// On Android a Google Maps route goes to the Maps app through an intent bound
/// to its package: a browser would quietly keep three waypoints and drop the
/// rest, and #60 says no stop is dropped. Without Maps it returns false. A
/// Waze link loses nothing in a browser (it takes one stop), so it may open as
/// a web page. On the web both open in a new tab.
class UrlLauncherNavigationAppOpener implements NavigationAppOpener {
  const UrlLauncherNavigationAppOpener();

  static const _channel = MethodChannel('jeeves/navigation_app');

  @override
  Future<bool> open(NavigationApp app, Uri uri) async {
    try {
      if (app == NavigationApp.googleMaps &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android) {
        final opened = await _channel.invokeMethod<bool>(
          'openInGoogleMaps',
          {'url': uri.toString()},
        );
        return opened ?? false;
      }
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      return false;
    }
  }
}
