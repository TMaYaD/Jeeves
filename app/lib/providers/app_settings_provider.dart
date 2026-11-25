/// Where the app's own settings live (issue #55).
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_settings_opener.dart';

/// The app's settings page. A journey overrides this with a recording fake.
final appSettingsOpenerProvider = Provider<AppSettingsOpener>((ref) {
  if (kIsWeb) return const NoAppSettingsOpener();
  return const MethodChannelAppSettingsOpener();
});
