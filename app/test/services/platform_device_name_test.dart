@TestOn('!browser')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/platform_device_name.dart';
// The channel belongs to the native adapter, which the conditional export in
// `platform_device_name.dart` hides behind a web default. This test only runs
// off the browser, so it may name the native adapter directly — prefixed, so
// the two libraries do not fight over `readPlatformDeviceName`.
import 'package:jeeves/services/platform_device_name_io.dart' as native;
import 'package:jeeves/services/user_agent_device_name.dart';

void main() {
  // The channel is a platform channel, so the test needs the binding that
  // owns the binary messenger it is mocked on.
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(native.deviceNameChannel, null),
  );

  group('readPlatformDeviceName', () {
    test('returns the platform answer, trimmed', () async {
      messenger.setMockMethodCallHandler(
        native.deviceNameChannel,
        (call) async => '  Pixel 8 Pro  ',
      );

      expect(await readPlatformDeviceName(), 'Pixel 8 Pro');
    });

    test('a blank answer is no name', () async {
      messenger.setMockMethodCallHandler(
        native.deviceNameChannel,
        (call) async => '   ',
      );

      expect(await readPlatformDeviceName(), isNull);
    });

    test('no platform answer at all is no name', () async {
      // No handler: the platform has nothing to say, which is the honest
      // signal that this device offers no name.
      expect(await readPlatformDeviceName(), isNull);
    });

    test('a platform error is no name', () async {
      messenger.setMockMethodCallHandler(native.deviceNameChannel, (call) async {
        throw PlatformException(code: 'device_name_unavailable');
      });

      expect(await readPlatformDeviceName(), isNull);
    });
  });

  group('deviceNameFromUserAgent', () {
    test('Chrome on Windows', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        ),
        'Chrome on Windows',
      );
    });

    test('Chrome on Android says Android, not Linux', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        ),
        'Chrome on Android',
      );
    });

    test('Safari on macOS', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
          '(KHTML, like Gecko) Version/17.6 Safari/605.1.15',
        ),
        'Safari on macOS',
      );
    });

    test('Safari on iPhone says iOS, not macOS', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 '
          'Safari/604.1',
        ),
        'Safari on iOS',
      );
    });

    test('Firefox on Linux', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 '
          'Firefox/133.0',
        ),
        'Firefox on Linux',
      );
    });

    test('Edge on Windows says Edge, not Chrome', () {
      expect(
        deviceNameFromUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
        ),
        'Edge on Windows',
      );
    });

    test('an empty user agent is no name', () {
      expect(deviceNameFromUserAgent(''), isNull);
    });
  });
}
