import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Set by CI with `--dart-define=JEEVES_GIT_SHA=<short sha>`; empty for local
/// builds.
const _commitSha = String.fromEnvironment('JEEVES_GIT_SHA');

/// `Version <name> (<code>)`, plus ` · <sha>` when the build carries a sha.
String buildVersionLabel({
  required String versionName,
  required String versionCode,
  String commitSha = '',
}) {
  final label = 'Version $versionName ($versionCode)';
  return commitSha.isEmpty ? label : '$label · $commitSha';
}

/// The running build's label, read from the installed package metadata (the
/// same source `adb shell dumpsys package` reports).
final buildVersionLabelProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return buildVersionLabel(
    versionName: info.version,
    versionCode: info.buildNumber,
    commitSha: _commitSha,
  );
});
