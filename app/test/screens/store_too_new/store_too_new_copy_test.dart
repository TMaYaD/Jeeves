/// Every sentence the too-new-store screen can say, held against the rules
/// that make it sayable.
///
/// Three rules, all of them decaying silently:
///
/// 1. **The vocabulary is the user's.** A user who put back an older build is
///    asking about their data. They have data, a phone and a version. They do
///    not have schemas, stores, rows or migrations — and are never shown one.
/// 2. **Plain voice, no Jeeves register.** This surface deliberately opts out,
///    as the sync-health surface does.
/// 3. **The screen says the one thing that matters**: the data is intact and
///    nothing was changed or deleted. A rewrite that loses either half of that
///    is the failure this test exists to catch.
///
/// Pure Dart, no Flutter import: the sentences are asserted without pumping a
/// widget. The screen that shows them is `store_too_new_screen_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/screens/store_too_new/store_too_new_copy.dart';

/// Every string this surface can put in front of a user.
List<({String where, String text})> _everyString() => [
      (where: 'screen title', text: storeTooNewTitle),
      (where: 'explanation', text: storeTooNewExplanation),
      (where: 'advice', text: storeTooNewAdvice),
      (where: 'running-version label', text: storeTooNewRunningVersionLabel),
    ];

/// The strings that are sentences: the title is a headline and the
/// running-version label is a caption, and neither takes a full stop.
List<({String where, String text})> _everySentence() => [
      (where: 'explanation', text: storeTooNewExplanation),
      (where: 'advice', text: storeTooNewAdvice),
    ];

bool _containsWord(String haystack, String word) =>
    RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false)
        .hasMatch(haystack);

void main() {
  group('the vocabulary is the user\'s', () {
    test('no banned word reaches any sentence', () {
      for (final sentence in _everyString()) {
        for (final word in storeTooNewBannedWords) {
          expect(
            _containsWord(sentence.text, word),
            isFalse,
            reason: '"${sentence.where}" says "$word": ${sentence.text}',
          );
        }
      }
    });

    test('no sentence carries a machine code', () {
      final snakeCase = RegExp(r'\b[a-z]+_[a-z_]+\b');
      for (final sentence in _everyString()) {
        expect(
          snakeCase.hasMatch(sentence.text),
          isFalse,
          reason: '"${sentence.where}" leaks a raw code: ${sentence.text}',
        );
      }
    });

    test('no sentence speaks in the Jeeves register', () {
      for (final sentence in _everyString()) {
        for (final marker in storeTooNewBannedVoiceMarkers) {
          expect(
            _containsWord(sentence.text, marker),
            isFalse,
            reason: '"${sentence.where}" is in Jeeves voice: ${sentence.text}',
          );
        }
        expect(sentence.text, isNot(contains('!')));
      }
    });
  });

  group('the screen says what matters', () {
    test('every sentence ends in a full stop', () {
      for (final sentence in _everySentence()) {
        if (sentence.text.trim().isEmpty) continue;
        expect(sentence.text.trim(), endsWith('.'),
            reason: '"${sentence.where}" is not a sentence: ${sentence.text}');
      }
    });

    test('it says the data was used by a newer version', () {
      expect(
        _containsWord(storeTooNewExplanation, 'newer'),
        isTrue,
        reason: 'the user has to learn that the data belongs to a newer '
            'Jeeves: $storeTooNewExplanation',
      );
      expect(storeTooNewExplanation, contains('newer version of Jeeves'));
    });

    test('it says this version cannot read the data', () {
      expect(
        storeTooNewExplanation.toLowerCase(),
        contains('cannot read'),
        reason: 'the user has to learn why the data is not on screen: '
            '$storeTooNewExplanation',
      );
    });

    test('it says nothing was changed and nothing was deleted', () {
      expect(storeTooNewExplanation, contains('Nothing was changed.'));
      expect(storeTooNewExplanation, contains('Nothing was deleted.'),
          reason: 'a user who put back an older build needs to be told that '
              'their data is still there');
    });

    test('it says what to do, without offering to do it here', () {
      expect(storeTooNewAdvice, contains('Install the newest version'));
      expect(
        storeTooNewAdvice.toLowerCase(),
        isNot(contains('uninstall')),
        reason: 'the answer is a newer build, never the removal of this one',
      );
    });

    test('it names the running version, so a user can tell which build they '
        'are looking at', () {
      expect(storeTooNewRunningVersionLabel, 'Running version: ');
    });
  });
}
