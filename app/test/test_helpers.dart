import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';

/// Call once before any test that uses [NativeDatabase].
///
/// sqlite3 >=3.0 loads the native library via build hooks rather than
/// runtime [DynamicLibrary] overrides, so no manual path fixup is needed.
void configureSqliteForTests() {}

/// No-ops the platform-channel notification calls made by ritual providers
/// (`startDay` / `closeDay` skip today's reminder on close). Unit and widget
/// tests wire this in via `notificationServiceProvider.overrideWithValue(...)`
/// so they never touch a real plugin.
class StubNotificationService extends NotificationService {
  StubNotificationService() : super.forTesting();

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}
}
