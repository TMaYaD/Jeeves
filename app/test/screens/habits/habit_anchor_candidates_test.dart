import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/screens/habits/habit_anchor_candidates.dart';

Habit _habit(String id, {String? anchorId, String kind = 'none'}) => Habit(
      id: id,
      userId: 'u',
      title: id,
      notes: null,
      energyLevel: null,
      timeEstimateMinutes: null,
      anchorPartOfDay: null,
      anchorClockTime: null,
      updatedAt: null,
      anchorKind: anchorId == null ? 'none' : kind,
      anchorHabitId: anchorId,
      createdAt: '2026-11-01T00:00:00.000Z',
    );

void main() {
  test('a loop through three Habits is refused', () {
    final a = _habit('a');
    final b = _habit('b', anchorId: 'a', kind: 'after_habit');
    final c = _habit('c', anchorId: 'b', kind: 'before_habit');
    final all = [a, b, c];
    final ids = {'a', 'b', 'c'};
    expect(anchorCandidates(a, all, ids).map((h) => h.id), isEmpty);
    expect(anchorCandidates(b, all, ids).map((h) => h.id), ['a']);
    expect(anchorCandidates(c, all, ids).map((h) => h.id), ['a', 'b']);
  });

  test('replacing an anchor frees the Habits it blocked', () {
    final a = _habit('a');
    final b = _habit('b', anchorId: 'a', kind: 'after_habit');
    expect(anchorCandidates(a, [a, b], {'a', 'b'}), isEmpty);
    final freed = _habit('b');
    expect(anchorCandidates(a, [a, freed], {'a', 'b'}).map((h) => h.id), ['b']);
  });

  test('paused and archived Habits are not offered, but still carry a loop',
      () {
    final a = _habit('a');
    final b = _habit('b', anchorId: 'a', kind: 'after_habit');
    final c = _habit('c', anchorId: 'b', kind: 'after_habit');
    final d = _habit('d');
    // b is paused: not offered, and c still reaches a through b.
    final offered = anchorCandidates(a, [a, b, c, d], {'a', 'c', 'd'});
    expect(offered.map((h) => h.id), ['d']);
  });
}
