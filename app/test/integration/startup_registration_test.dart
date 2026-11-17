/// The app's startup, from the first thing it does to the first frame.
///
/// The journey over the blocking screen starts at `JeevesApp`, so it never
/// went through the code that registers the notification callbacks — and that
/// code is where a background callback the plugin cannot resolve stops the app
/// from starting at all.
///
/// The plugin here is the real one, on a real method channel with the platform
/// mocked underneath. That is the point: the plugin resolves the background
/// callback by handle, and the resolution — not a stand-in for it — is what is
/// under test.
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:ui' show PluginUtilities;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/store_refusal_error.dart';
import 'package:jeeves/main.dart';
import 'package:jeeves/providers/build_version_provider.dart';
import 'package:jeeves/providers/nudge_action_outbox.dart';
import 'package:jeeves/screens/store_blocked/store_blocked_screen.dart';
import 'package:jeeves/services/notification_background_entry_point.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test_helpers.dart';

const MethodChannel _notificationsChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');
const MethodChannel _timezoneChannel = MethodChannel('flutter_timezone');
const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');

const String _versionLabel = 'Version 1.0.0-alpha.1951 (1951)';

/// A store file carrying [version], and nothing else.
void _writeStoreFile(String path, int version) {
  final database = sqlite3.open(path);
  try {
    database.userVersion = version;
  } finally {
    database.close();
  }
}

/// Waits for [condition] to hold, and says whether it ever did.
Future<bool> _waitFor(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<MethodCall> pluginCalls;
  late FlutterLocalNotificationsPlatform originalPlatform;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    originalPlatform = FlutterLocalNotificationsPlatform.instance;
  });

  setUp(() {
    configureSqliteForTests();
    directory = Directory.systemTemp.createTempSync('jeeves_startup_');
    pluginCalls = [];

    // The plugin picks its platform implementation by the running platform,
    // and a test runs on the host's: say Android, which is the fleet.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();

    messenger.setMockMethodCallHandler(_notificationsChannel, (call) async {
      pluginCalls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'requestNotificationsPermission':
          return true;
        case 'getNotificationAppLaunchDetails':
          return null;
        case 'pendingNotificationRequests':
          return <Object>[];
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(
        _timezoneChannel, (call) async => 'UTC');
    messenger.setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return directory.path;
      }
      return null;
    });

    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_notificationsChannel, null);
    messenger.setMockMethodCallHandler(_timezoneChannel, null);
    messenger.setMockMethodCallHandler(_pathProviderChannel, null);
    try {
      directory.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  tearDownAll(() {
    FlutterLocalNotificationsPlatform.instance = originalPlatform;
  });

  /// The platform delivering a notification action tap to the running app.
  Future<void> deliverTap(String actionId, String payload) async {
    await messenger.handlePlatformMessage(
      _notificationsChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', {
          'notificationId': 1,
          'actionId': actionId,
          'input': null,
          'payload': payload,
          'notificationResponseType':
              NotificationResponseType.selectedNotificationAction.index,
        }),
      ),
      (_) {},
    );
  }

  /// The outbox entries the app recorded for a notification action.
  Future<List<String>> recordedActions() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((key) => key.startsWith(kNudgeActionOutboxKeyPrefix))
        .toList();
  }

  test('the app starts, and the plugin can call the background callback',
      () async {
    final versions = await prepareStartup();

    expect(versions.refusal, isNull);

    final initialize =
        pluginCalls.firstWhere((call) => call.method == 'initialize');
    final arguments = initialize.arguments as Map<Object?, Object?>;
    expect(arguments['callback_handle'], isNotNull,
        reason: 'the plugin starts a background engine and calls the callback '
            'by handle');
    expect(
      arguments['callback_handle'],
      PluginUtilities.getCallbackHandle(handleBackgroundNotificationResponse)!
          .toRawHandle(),
      reason: 'the handle the plugin was given has to be the one of the '
          'top-level function the app registers',
    );
  });

  test('a closure has no handle, and the background callback has one', () {
    // The plugin resolves the background callback by handle and dereferences
    // it without checking: a callback with no handle stops the app from
    // starting at all. This is the rule the registration has to keep.
    expect(
      PluginUtilities.getCallbackHandle((NotificationResponse response) {}),
      isNull,
      reason: 'a closure captures, and a captured function has no handle',
    );
    expect(
      PluginUtilities.getCallbackHandle(handleBackgroundNotificationResponse),
      isNotNull,
      reason: 'the function the app registers has to be one the plugin can '
          'call from the engine it starts',
    );
  });

  test('the foreground callback is registered separately, and it acts',
      () async {
    await prepareStartup();

    // A Skip tap on a Nudge notification, delivered by the platform.
    await deliverTap(kNotificationActionSkip, 'nudge:planning');

    expect(
      await _waitFor(() async => (await recordedActions()).isNotEmpty),
      isTrue,
      reason: 'the foreground callback is the one the platform calls when the '
          'app is running, and it has to reach the handler',
    );
  });

  test('a store this build cannot read stops the foreground action too',
      () async {
    _writeStoreFile(
      p.join(directory.path, domainStoreFileName),
      GtdDatabase.supportedSchemaVersion + 1,
    );

    await prepareStartup();
    await deliverTap(kNotificationActionSkip, 'nudge:planning');

    // The handler records the tap in the very store this build cannot read,
    // so it does nothing at all.
    expect(await recordedActions(), isEmpty,
        reason: 'a store this build cannot open is not this build\'s to write '
            'into');
  });

  testWidgets('a store this build cannot read stops the app before the '
      'first frame', (tester) async {
    _writeStoreFile(
      p.join(directory.path, domainStoreFileName),
      GtdDatabase.supportedSchemaVersion + 1,
    );

    final versions = (await tester.runAsync(prepareStartup))!;

    expect(versions.refusal, isA<StoreVersionTooNewError>());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          buildVersionLabelProvider.overrideWith((ref) async => _versionLabel),
        ],
        child: JeevesApp(storeVersions: versions),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StoreBlockedScreen), findsOneWidget);
  });
}
