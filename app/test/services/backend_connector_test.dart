import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

import 'package:jeeves/services/backend_connector.dart';

CrudEntry _entry(String table, UpdateType op) =>
    CrudEntry(1, op, table, 'row-id', null, const <String, dynamic>{});

void main() {
  group('JevesBackendConnector.isSilentDataLossDrop', () {
    // The connector's debug assert refuses to silently drop a user_preferences
    // upload on a fatal 4xx (the #306 read-side wipe). These cases lock in which
    // dropped entries trip that guard.
    test('a non-delete user_preferences write trips the guard', () {
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.put)),
        isTrue,
      );
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.patch)),
        isTrue,
      );
    });

    test('a user_preferences delete is exempt (idempotent 404)', () {
      expect(
        JevesBackendConnector.isSilentDataLossDrop(
            _entry('user_preferences', UpdateType.delete)),
        isFalse,
      );
    });

    test('other tables never trip the guard', () {
      for (final table in [
        'todos',
        'tags',
        'todo_tags',
        'focus_sessions',
        'focus_session_tasks',
        'time_logs',
      ]) {
        for (final op in UpdateType.values) {
          expect(
            JevesBackendConnector.isSilentDataLossDrop(_entry(table, op)),
            isFalse,
            reason: '$table / $op should not be flagged',
          );
        }
      }
    });
  });
}
