/// Every sentence the blocking screen can say, held against the rules that
/// make it sayable.
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
/// There are two sets of sentences, one per reason the app cannot open the
/// stores, and both are held to the same rules. The unreadable set has one
/// rule of its own: it must not claim the data belongs to a newer Jeeves,
/// because nothing in this case knows that.
///
/// Pure Dart, no Flutter import: the sentences are asserted without pumping a
/// widget. The screen that shows them is `store_blocked_screen_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/screens/store_blocked/store_blocked_copy.dart';
import 'package:jeeves/screens/store_blocked/store_too_new_copy.dart';
import 'package:jeeves/screens/store_blocked/store_unreadable_copy.dart';

/// The two sets of sentences, and what each of them is for.
List<({String where, StoreBlockedCopy copy})> _everyCopy() => [
      (where: 'the too-new screen', copy: storeTooNewCopy),
      (where: 'the unreadable screen', copy: storeUnreadableCopy),
    ];

/// Every string this surface can put in front of a user.
List<({String where, String text})> _everyString() => [
      for (final entry in _everyCopy()) ...[
        (where: '${entry.where} title', text: entry.copy.title),
        (where: '${entry.where} explanation', text: entry.copy.explanation),
        (where: '${entry.where} advice', text: entry.copy.advice),
      ],
      (
        where: 'running-version label',
        text: storeBlockedRunningVersionLabel,
      ),
    ];

/// The strings that are sentences: the titles are headlines and the
/// running-version label is a caption, and none of them takes a full stop.
List<({String where, String text})> _everySentence() => [
      for (final entry in _everyCopy()) ...[
        (where: '${entry.where} explanation', text: entry.copy.explanation),
        (where: '${entry.where} advice', text: entry.copy.advice),
      ],
    ];

bool _containsWord(String haystack, String word) =>
    RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false)
        .hasMatch(haystack);

void main() {
  group('the vocabulary is the user\'s', () {
    test('no banned word reaches any sentence', () {
      for (final sentence in _everyString()) {
        for (final word in storeBlockedBannedWords) {
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
        for (final marker in storeBlockedBannedVoiceMarkers) {
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

    test('both screens say nothing was changed and nothing was deleted', () {
      for (final entry in _everyCopy()) {
        expect(entry.copy.explanation, contains('Nothing was changed.'),
            reason: entry.where);
        expect(entry.copy.explanation, contains('Nothing was deleted.'),
            reason:
                'a user who put back an older build needs to be told that '
                'their data is still there');
      }
    });

    test('it names the running version, so a user can tell which build they '
        'are looking at', () {
      expect(storeBlockedRunningVersionLabel, 'Running version: ');
    });
  });

  group('the too-new screen', () {
    test('it says the data was used by a newer version', () {
      expect(
        _containsWord(storeTooNewCopy.explanation, 'newer'),
        isTrue,
        reason: 'the user has to learn that the data belongs to a newer '
            'Jeeves: ${storeTooNewCopy.explanation}',
      );
      expect(storeTooNewCopy.explanation, contains('newer version of Jeeves'));
    });

    test('it says this version cannot read the data', () {
      expect(
        storeTooNewCopy.explanation.toLowerCase(),
        contains('cannot read'),
        reason: 'the user has to learn why the data is not on screen: '
            '${storeTooNewCopy.explanation}',
      );
    });

    test('it says what to do, without offering to do it here', () {
      expect(storeTooNewCopy.advice, contains('Install the newest version'));
      expect(
        storeTooNewCopy.advice.toLowerCase(),
        isNot(contains('uninstall')),
        reason: 'the answer is a newer build, never the removal of this one',
      );
    });
  });

  group('the unreadable screen', () {
    test('it says the data could not be read', () {
      expect(
        storeUnreadableCopy.explanation.toLowerCase(),
        contains('could not read'),
        reason: 'the user has to learn why the data is not on screen: '
            '${storeUnreadableCopy.explanation}',
      );
    });

    test('it does not claim the data belongs to a newer Jeeves', () {
      // Nothing in this case knows that. The file could not be read, and a
      // file that cannot be read may or may not be one a newer build wrote.
      expect(
        _containsWord(storeUnreadableCopy.explanation, 'newer'),
        isFalse,
        reason: 'the screen must not say what it does not know: '
            '${storeUnreadableCopy.explanation}',
      );
      expect(
        _containsWord(storeUnreadableCopy.title, 'newer'),
        isFalse,
        reason: 'the screen must not say what it does not know: '
            '${storeUnreadableCopy.title}',
      );
    });

    test('it says what to do, without offering to do it here', () {
      expect(
        storeUnreadableCopy.advice.toLowerCase(),
        contains('open it again'),
        reason: 'a file that could not be read may read the next time',
      );
      expect(
        storeUnreadableCopy.advice.toLowerCase(),
        isNot(contains('uninstall')),
        reason: 'the answer is never the removal of this one',
      );
    });
  });
}
