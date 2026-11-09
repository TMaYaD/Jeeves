import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/build_version_provider.dart';

void main() {
  test('label includes version name, version code and sha', () {
    expect(
      buildVersionLabel(
        versionName: '1.3.0-alpha.17',
        versionCode: '412',
        commitSha: 'a1b2c3d',
      ),
      'Version 1.3.0-alpha.17 (412) · a1b2c3d',
    );
  });

  test('label omits the sha and its separator when the build has none', () {
    final label = buildVersionLabel(versionName: '1.0.0', versionCode: '1');
    expect(label, 'Version 1.0.0 (1)');
    expect(label, isNot(contains('·')));
  });
}
