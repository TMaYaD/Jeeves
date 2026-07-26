/// Unit tests for [ClarifyDraft.assemble] — the assembly rule every clarify
/// surface shares.
///
/// Pure: no database, no widget, no pump. That is the point of the extraction —
/// the blank-title rule, the person-hint exclusion and the calendar-day
/// truncation were previously provable only by driving a whole card.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

const _userId = 'local';

Tag _tag(String id, String type) =>
    Tag(id: id, name: id, type: type, userId: _userId);

/// Every argument supplied, so each test overrides exactly the one field it is
/// making a claim about and nothing is accidentally left at a value that would
/// make the assertion true either way.
ClarifyDraft _assemble({
  String title = 'Buy milk',
  String notes = '',
  DateTime? dueDate,
  List<Tag> hintTags = const <Tag>[],
  Set<String>? draftTagIds,
  String? energyLevel,
  int? timeEstimateMinutes,
}) =>
    ClarifyDraft.assemble(
      title: title,
      notes: notes,
      dueDate: dueDate,
      hintTags: hintTags,
      draftTagIds: draftTagIds,
      energyLevel: energyLevel,
      timeEstimateMinutes: timeEstimateMinutes,
    );

void main() {
  group('ClarifyDraft.assemble — the Action grain', () {
    test('a blank title nulls the whole action, effort values and all', () {
      // Effort deliberately non-null: the rule is that a blank phrase nulls
      // the *whole* draft rather than carrying live effort beside an empty
      // phrase, and a null-effort fixture could not tell the two apart.
      final draft = _assemble(
        title: '   ',
        energyLevel: 'high',
        timeEstimateMinutes: 30,
      );

      expect(draft.action, isNull);
      expect(draft.title, '');
    });

    test('a non-blank title mirrors into the action with its effort', () {
      final draft = _assemble(
        title: '  Buy oat milk  ',
        energyLevel: 'low',
        timeEstimateMinutes: 15,
      );

      expect(draft.title, 'Buy oat milk');
      expect(draft.action?.text, 'Buy oat milk');
      expect(draft.action?.energyLevel, 'low');
      expect(draft.action?.timeEstimateMinutes, 15);
    });

    test('a title that is only whitespace is blank, not a one-space title', () {
      // `title` is what names the Outcome, so the trim has to happen before
      // the blank test — otherwise ' ' routes and mints an Outcome named ' '.
      expect(_assemble(title: '\n\t ').title, '');
      expect(_assemble(title: '\n\t ').action, isNull);
    });
  });

  group('ClarifyDraft.assemble — notes', () {
    test('an empty notes field becomes null, not an empty string', () {
      // Every `notes == null` read treats `''` as "has notes".
      expect(_assemble(notes: '   ').notes, isNull);
    });

    test('notes are trimmed', () {
      expect(_assemble(notes: '  Full fat  ').notes, 'Full fat');
    });
  });

  group('ClarifyDraft.assemble — tags', () {
    test('person hints are excluded; other hints travel', () {
      // Both kinds present, or "excluded" is unfalsifiable.
      final draft = _assemble(hintTags: [
        _tag('c1', 'context'),
        _tag('p1', 'project'),
        _tag('per1', 'person'),
      ]);

      expect(draft.tagIds, {'c1', 'p1'});
    });

    test('a supplied draft set wins over the hints', () {
      // The synchronous draft is what a picker mutates; the hint stream is a
      // frame behind it. Distinct ids on both sides so "wins" is observable.
      final draft = _assemble(
        hintTags: [_tag('stale', 'context')],
        draftTagIds: {'fresh'},
      );

      expect(draft.tagIds, {'fresh'});
    });

    test('a person id is dropped from the draft set too', () {
      // The picker cannot add a person tag, but a *seeded* draft starts life
      // as the hints — so the exclusion has to survive the seeding.
      final draft = _assemble(
        hintTags: [_tag('per1', 'person'), _tag('c1', 'context')],
        draftTagIds: {'per1', 'c1'},
      );

      expect(draft.tagIds, {'c1'});
    });

    test('an empty draft set is honoured — it is not "no draft"', () {
      // A user who removed every tag must not have the hints reinstated.
      final draft = _assemble(
        hintTags: [_tag('c1', 'context')],
        draftTagIds: const <String>{},
      );

      expect(draft.tagIds, isEmpty);
    });
  });

  group('ClarifyDraft.assemble — due date', () {
    test('is truncated to the calendar day', () {
      // A non-midnight time, or truncation proves nothing.
      final draft = _assemble(dueDate: DateTime(2026, 3, 9, 17, 42, 13));

      expect(draft.dueDate, DateTime(2026, 3, 9));
    });

    test('a null due date stays null', () {
      expect(_assemble(dueDate: null).dueDate, isNull);
    });
  });
}
