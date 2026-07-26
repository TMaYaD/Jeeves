/// Unit tests for [RetainedClarifyDraft.seedFrom] and [ClarifyRetention].
///
/// `seedFrom` is the only place the retention conflict rule is provable
/// without a stream: a card test pushes the values itself, so a reconciler
/// that ran on every emission — clobbering typing whenever a real drift query
/// re-emits — would never be caught there.
///
/// Every fixture below uses three *distinct* strings. If the retained value,
/// its baseline and the incoming value coincide, every branch produces the
/// same answer and the test proves nothing.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/clarify_retention.dart';

/// A draft the user has typed into: [title] differs from its baseline.
RetainedClarifyDraft _dirtyTitle({
  String title = 'typed title',
  String baselineTitle = 'seeded title',
  String notes = 'seeded notes',
  String baselineNotes = 'seeded notes',
}) =>
    RetainedClarifyDraft(
      title: title,
      notes: notes,
      baselineTitle: baselineTitle,
      baselineNotes: baselineNotes,
    );

void main() {
  group('RetainedClarifyDraft.seedFrom — no retained entry', () {
    test('the row wins outright and becomes the baseline', () {
      final seeded = RetainedClarifyDraft.seedFrom(
        null,
        incomingTitle: 'Buy milk',
        incomingNotes: 'Full fat',
      );

      expect(seeded.title, 'Buy milk');
      expect(seeded.notes, 'Full fat');
      expect(seeded.baselineTitle, 'Buy milk');
      expect(seeded.baselineNotes, 'Full fat');
      expect(seeded.titleIsDirty, isFalse);
    });

    test('null notes seed an empty field, not the string "null"', () {
      final seeded = RetainedClarifyDraft.seedFrom(
        null,
        incomingTitle: 'Buy milk',
        incomingNotes: null,
      );

      expect(seeded.notes, '');
      expect(seeded.baselineNotes, '');
      expect(seeded.notesIsDirty, isFalse);
    });
  });

  group('RetainedClarifyDraft.seedFrom — a clean retained field', () {
    test('adopts an incoming change', () {
      final retained = RetainedClarifyDraft(
        title: 'seeded title',
        notes: 'seeded notes',
        baselineTitle: 'seeded title',
        baselineNotes: 'seeded notes',
      );

      final seeded = RetainedClarifyDraft.seedFrom(
        retained,
        // Differs from both the draft and its baseline, so adoption is
        // observable rather than assumed.
        incomingTitle: 'incoming title',
        incomingNotes: 'incoming notes',
      );

      expect(seeded.title, 'incoming title');
      expect(seeded.baselineTitle, 'incoming title');
      expect(seeded.notes, 'incoming notes');
      expect(seeded.baselineNotes, 'incoming notes');
      expect(seeded.titleIsDirty, isFalse,
          reason: 'an adopted field is clean, so the next incoming change may '
              'be applied to it too');
    });
  });

  group('RetainedClarifyDraft.seedFrom — a dirty retained field', () {
    test('the draft wins and the stale baseline is kept', () {
      final seeded = RetainedClarifyDraft.seedFrom(
        _dirtyTitle(),
        incomingTitle: 'incoming title',
        incomingNotes: 'seeded notes',
      );

      expect(seeded.title, 'typed title', reason: 'an edit in progress wins');
      expect(seeded.baselineTitle, 'seeded title',
          reason: 'keeping the stale baseline restores the field\'s dirty '
              'state, so the live listener keeps leaving it alone. Advancing '
              'it to the incoming value would make the field read clean and '
              'let the next incoming change silently overwrite the typing');
      expect(seeded.titleIsDirty, isTrue);
    });

    test('the same holds for notes, with the title clean', () {
      // The rule is stated once and applied to both fields, so it has to be
      // proved on both: every other dirty-branch case above pins a dirty
      // *title*, and advancing `baselineNotes` on the dirty branch would
      // survive all of them.
      final retained = RetainedClarifyDraft(
        title: 'seeded title',
        baselineTitle: 'seeded title',
        notes: 'typed notes',
        baselineNotes: 'seeded notes',
      );

      final seeded = RetainedClarifyDraft.seedFrom(
        retained,
        incomingTitle: 'seeded title',
        incomingNotes: 'incoming notes',
      );

      expect(seeded.notes, 'typed notes', reason: 'an edit in progress wins');
      expect(seeded.baselineNotes, 'seeded notes',
          reason: 'the stale baseline restores the field\'s dirty state; '
              'advancing it to the incoming value would make the notes read '
              'clean and let the next incoming change overwrite the typing');
      expect(seeded.notesIsDirty, isTrue);
    });

    test('re-seeding twice against the same row still keeps the typing', () {
      // The trap a hand-cranked stream hides: a reconciler that ran on every
      // emission would survive one push and lose the typing on the second.
      var seeded = RetainedClarifyDraft.seedFrom(
        _dirtyTitle(),
        incomingTitle: 'incoming title',
        incomingNotes: 'seeded notes',
      );
      seeded = RetainedClarifyDraft.seedFrom(
        seeded,
        incomingTitle: 'incoming title',
        incomingNotes: 'seeded notes',
      );

      expect(seeded.title, 'typed title');
      expect(seeded.baselineTitle, 'seeded title');
    });

    test('reconciliation is per field: a dirty title does not pin clean notes',
        () {
      // Four distinct strings across the two fields, so a reconciler that
      // decided once for the whole record would show up here.
      final retained = RetainedClarifyDraft(
        title: 'typed title',
        baselineTitle: 'seeded title',
        notes: 'seeded notes',
        baselineNotes: 'seeded notes',
      );

      final seeded = RetainedClarifyDraft.seedFrom(
        retained,
        incomingTitle: 'incoming title',
        incomingNotes: 'incoming notes',
      );

      expect(seeded.title, 'typed title', reason: 'dirty: the draft wins');
      expect(seeded.notes, 'incoming notes', reason: 'clean: adopted');
      expect(seeded.baselineTitle, 'seeded title');
      expect(seeded.baselineNotes, 'incoming notes');
    });

    test('the draft-only attributes always survive', () {
      // Energy, estimate and due date have no column on a Capture, so there is
      // no incoming value that could win — but before retention they were lost
      // on every unmount.
      final retained = RetainedClarifyDraft(
        title: 'seeded title',
        notes: 'seeded notes',
        baselineTitle: 'seeded title',
        baselineNotes: 'seeded notes',
        energyLevel: 'high',
        timeEstimateMinutes: 30,
        dueDate: DateTime(2026, 3, 9),
      );

      // Seeded against a *changed* row, so the clean path is the one taken —
      // the branch most likely to drop them.
      final seeded = RetainedClarifyDraft.seedFrom(
        retained,
        incomingTitle: 'incoming title',
        incomingNotes: 'incoming notes',
      );

      expect(seeded.energyLevel, 'high');
      expect(seeded.timeEstimateMinutes, 30);
      expect(seeded.dueDate, DateTime(2026, 3, 9));
    });
  });

  group('RetainedClarifyDraft — dirtiness is measured on trimmed text', () {
    test('trailing whitespace alone is not an edit', () {
      // The card's live binding compares trimmed text, so the two notions of
      // clean have to agree or a stray space would freeze the field.
      final retained = RetainedClarifyDraft(
        title: '  Buy milk  ',
        notes: '',
        baselineTitle: 'Buy milk',
        baselineNotes: '',
      );

      expect(retained.titleIsDirty, isFalse);
      expect(
        RetainedClarifyDraft.seedFrom(
          retained,
          incomingTitle: 'Buy oat milk',
          incomingNotes: null,
        ).title,
        'Buy oat milk',
      );
    });
  });

  group('ClarifyRetention', () {
    test('stash then read returns the draft; an unknown id returns null', () {
      final store = ClarifyRetention();
      store.stash('a', _dirtyTitle());

      expect(store.read('a')?.title, 'typed title');
      expect(store.read('b'), isNull);
    });

    test('drafts are keyed per Capture', () {
      final store = ClarifyRetention()
        ..stash('a', _dirtyTitle(title: 'draft for a'))
        ..stash('b', _dirtyTitle(title: 'draft for b'));

      expect(store.read('a')?.title, 'draft for a');
      expect(store.read('b')?.title, 'draft for b');
    });

    test('discard drops one Capture and leaves the rest', () {
      final store = ClarifyRetention()
        ..stash('a', _dirtyTitle())
        ..stash('b', _dirtyTitle());

      store.discard('a');

      expect(store.read('a'), isNull);
      expect(store.read('b'), isNotNull,
          reason: 'a verdict on one Capture says nothing about another');
    });

    test('clearAll empties the store', () {
      final store = ClarifyRetention()
        ..stash('a', _dirtyTitle())
        ..stash('b', _dirtyTitle());

      store.clearAll();

      expect(store.read('a'), isNull);
      expect(store.read('b'), isNull);
    });
  });
}
