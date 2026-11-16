/// Android system backup must carry no Jeeves data: a restored phone would
/// otherwise inherit the source phone's device identity and sync state.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _domains = [
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
  'device_root',
  'device_file',
  'device_database',
  'device_sharedpref',
];

String _read(String path) => File(path).readAsStringSync();

void _expectExcludesEveryDomain(String xml, {required String where}) {
  for (final domain in _domains) {
    expect(
      RegExp('<exclude\\s+domain="$domain"\\s+path="\\."\\s*/>').hasMatch(xml),
      isTrue,
      reason: '$where must exclude domain "$domain"',
    );
  }
}

void main() {
  const resDir = 'android/app/src/main/res/xml';

  test('manifest opts out of backup and references both rule files', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest,
        contains('android:fullBackupContent="@xml/full_backup_content"'));
    expect(manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
  });

  test('Android 11 and lower rules exclude every domain', () {
    final xml = _read('$resDir/full_backup_content.xml');
    _expectExcludesEveryDomain(xml, where: 'full_backup_content.xml');
    expect(xml, isNot(contains('<include')));
  });

  test('Android 12+ rules exclude every domain in cloud backup and transfer',
      () {
    final xml = _read('$resDir/data_extraction_rules.xml');
    expect(xml, isNot(contains('<include')));
    for (final section in ['cloud-backup', 'device-transfer']) {
      final match =
          RegExp('<$section[^>]*>([\\s\\S]*?)</$section>').firstMatch(xml);
      expect(match, isNotNull, reason: 'missing <$section>');
      _expectExcludesEveryDomain(match!.group(1)!, where: '<$section>');
    }
  });

  test('no other manifest sets a backup attribute', () {
    final src = Directory('android/app/src');
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('AndroidManifest.xml')) continue;
      if (f.path.contains('/src/main/')) continue;
      expect(
        RegExp('allowBackup|fullBackupContent|dataExtractionRules')
            .hasMatch(f.readAsStringSync()),
        isFalse,
        reason: f.path,
      );
    }
  });
}
