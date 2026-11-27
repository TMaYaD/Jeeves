/// The recording stand-in for the OS opening a map app (issue #60).
library;

import 'dart:async';

import 'package:jeeves/services/navigation_app_opener.dart';

/// Remembers every link Jeeves opened, and answers what the test says.
class FakeNavigationAppOpener implements NavigationAppOpener {
  FakeNavigationAppOpener({this.opens = true});

  /// Whether the app opens. False stands for an app that is not installed.
  bool opens;

  /// Every link Jeeves opened, in order, with the app it was for.
  final calls = <({NavigationApp app, Uri uri})>[];

  /// When set, `open` waits for it, which stands for a slow launch.
  Completer<void>? holdOpen;

  @override
  Future<bool> open(NavigationApp app, Uri uri) async {
    calls.add((app: app, uri: uri));
    await holdOpen?.future;
    return opens;
  }
}
