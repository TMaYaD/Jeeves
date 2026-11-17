/// The plugin's background notification callback, and the rule it obeys.
///
/// A background isolate has no Riverpod container and no memory of the launch
/// that started it, so the callback reads the two store files itself before it
/// does anything at all. A store this build cannot open is not this build's to
/// write into: the handler records what the user did in the very store this
/// build cannot read, so a refusal stops the action as firmly as it stops the
/// app from starting.
///
/// The last case is the control: the same tap, on a store this build can read,
/// is recorded. Without it, "nothing happened" would prove nothing.
@TestOn('!browser')
library;

import 'dart:io';
import 'dart:ui' show PluginUtilities;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/domain_store.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/nudge_action_outbox.dart';
import 'package:jeeves/services/notification_background_entry_point.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test_helpers.dart';

const MethodChannel _notificationsChannel =
    MethodChannel('dexterous.com/flutter/local_notifications');
const MethodChannel _pathProviderChannel =
    MethodChannel('plugins.flutter.io/path_provider');

/// A store file carrying [version], and nothing else.
void _writeStoreFile(String path, int version) {
  final database = sqlite3.open(path);
  try {
    database.userVersion = version;
  } finally {
    database.close();
  }
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
    directory =
        Directory.systemTemp.createTempSync('jeeves_background_entry_');
    pluginCalls = [];

    // The plugin picks its platform implementation by the running platform,
    // and a test runs on the host's: say Android, which is the fleet.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();

    messenger.setMockMethodCallHandler(_notificationsChannel, (call) async {
      pluginCalls.add(call);
      if (call.method == 'pendingNotificationRequests') return <Object>[];
      return null;
    });
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

  /// The outbox entries the app recorded for a notification action.
  Future<List<String>> recordedActions() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((key) => key.startsWith(kNudgeActionOutboxKeyPrefix))
        .toList();
  }

  NotificationResponse skipTap() => NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: kNotificationActionSkip,
        payload: 'nudge:planning',
      );

  test('the callback is one the plugin can call from its own engine', () {
    // The plugin resolves the background callback by handle and dereferences
    // it without checking, so a callback with no handle stops the app from
    // starting at all.
    expect(
      PluginUtilities.getCallbackHandle(handleBackgroundNotificationResponse),
      isNotNull,
      reason: 'the background callback has to be a top-level function',
    );
  });

  test('a store this build cannot read stops the action', () async {
    final storePath = p.join(directory.path, domainStoreFileName);
    _writeStoreFile(storePath, GtdDatabase.supportedSchemaVersion + 1);
    final bytesBefore = File(storePath).readAsBytesSync();

    await handleBackgroundNotificationAction(skipTap());

    expect(await recordedActions(), isEmpty,
        reason: 'the handler records the tap in the very store this build '
            'cannot read');
    expect(pluginCalls, isEmpty,
        reason: 'a refused action does not touch the OS either');
    expect(File(storePath).readAsBytesSync(), bytesBefore,
        reason: 'the store comes out of the refusal exactly as it went in');
  });

  test('a store this build can read lets the same action through', () async {
    await handleBackgroundNotificationAction(skipTap());

    expect(await recordedActions(), hasLength(1),
        reason: 'the control: without this, "nothing happened" would prove '
            'nothing');
  });
}
