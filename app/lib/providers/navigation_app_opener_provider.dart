/// The port for opening a map app (issue #60). A journey overrides it with a
/// recording fake.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/navigation_app_opener.dart';

final navigationAppOpenerProvider = Provider<NavigationAppOpener>(
  (ref) => const UrlLauncherNavigationAppOpener(),
);
