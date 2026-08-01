/// Every sentence the sync-health screen can say, held against the three rules
/// that make it sayable.
///
/// These are rules that decay silently: a kind added in a hurry picks up the
/// vocabulary of the code that raises it, and "another device" is the phrasing
/// that reads best right up until you ask which one. Holding the first drafts
/// against the device rule caught two of them breaking it before a line of the
/// screen existed, which is why all three live here rather than in a paragraph.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/screens/sync_health/sync_health_copy.dart';
import 'package:jeeves/sync/chain_verifier.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/sync_condition_class.dart';

/// Every string this surface can put in front of a user.
List<({String where, String text})> _everySentence() => [
      (where: 'screen title', text: syncHealthScreenTitle),
      (where: 'first-run explanation', text: syncHealthAllHandledExplanation),
      (where: 'needs-attention heading', text: syncHealthNeedsAttentionHeading),
      (where: 'handled heading', text: syncHealthHandledHeading),
      (where: 'worthKnowing tooltip', text: syncHealthWorthKnowingTooltip),
      (where: 'unknown condition', text: syncHealthUnknownConditionSentence),
      (where: 'unreadable refusal', text: syncHealthUnreadableRefusalSentence),
      for (final kind in IntegrityAlarmKind.values)
        (where: kind.code, text: sentenceForAlarmCode(kind.code)),
      for (final reason in SyncRejectionReason.values)
        if (syncConditionClassOfRefusal(reason) != SyncConditionClass.transient)
          (where: reason.code, text: sentenceForRefusalCode(reason.code)),
    ];

bool _containsWord(String haystack, String word) =>
    RegExp('\\b${RegExp.escape(word)}\\b', caseSensitive: false)
        .hasMatch(haystack);

void main() {
  group('every kind is accounted for', () {
    test('U1 each kind has a class and a non-empty sentence', () {
      for (final kind in IntegrityAlarmKind.values) {
        expect(
          sentenceForAlarmCode(kind.code),
          isNotEmpty,
          reason: '${kind.code} has no sentence',
        );
        expect(
          sentenceForAlarmCode(kind.code),
          isNot(syncHealthUnknownConditionSentence),
          reason: '${kind.code} fell through to the unknown-code sentence',
        );
        expect(classOfAlarmCode(kind.code), syncConditionClassOf(kind));
      }
    });

    test('U1b every sentence is a sentence, not a label', () {
      // The author's direction was per-kind description, not three generic
      // resolution labels reused across eight kinds — so a duplicate is a
      // regression toward the shape that was rejected.
      final sentences = [
        for (final kind in IntegrityAlarmKind.values) sentenceForAlarmCode(kind.code),
      ];
      expect(sentences.toSet(), hasLength(sentences.length),
          reason: 'two kinds share a sentence, so one of them is not described');
      for (final sentence in sentences) {
        expect(sentence, endsWith('.'));
        expect(sentence.split(' ').length, greaterThan(4));
      }
    });

    test('U2 an unknown stored code renders, and never throws', () {
      expect(
        () => sentenceForAlarmCode('invented_by_a_later_build'),
        returnsNormally,
      );
      expect(
        sentenceForAlarmCode('invented_by_a_later_build'),
        syncHealthUnknownConditionSentence,
      );
      expect(
        classOfAlarmCode('invented_by_a_later_build'),
        SyncConditionClass.reported,
        reason: 'a code we cannot classify carries no evidence that anything of '
            "the user's is stuck, so calling it an error would be unsupported",
      );
      expect(
        sentenceForRefusalCode('invented_by_a_later_build'),
        syncHealthUnknownConditionSentence,
      );
      expect(
        classOfRefusalCode('invented_by_a_later_build'),
        SyncConditionClass.reported,
      );
    });

    test('every reportable refusal reason has a sentence too', () {
      for (final reason in SyncRejectionReason.values) {
        if (syncConditionClassOfRefusal(reason) == SyncConditionClass.transient) {
          continue;
        }
        expect(
          sentenceForRefusalCode(reason.code),
          isNotEmpty,
          reason: '${reason.code} has no sentence',
        );
        expect(
          sentenceForRefusalCode(reason.code),
          isNot(syncHealthUnknownConditionSentence),
          reason: '${reason.code} is a code we know and should describe',
        );
      }
    });
  });

  group('U3 the vocabulary is the user\'s', () {
    test('no banned word reaches any sentence', () {
      for (final sentence in _everySentence()) {
        for (final word in syncHealthBannedWords) {
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
      for (final sentence in _everySentence()) {
        expect(
          snakeCase.hasMatch(sentence.text),
          isFalse,
          reason: '"${sentence.where}" leaks a raw code: ${sentence.text}',
        );
      }
    });

    test('no sentence names an anonymous singular peer', () {
      // Name *this* device, or name a set, or name nobody. The author's
      // objection was that "another device" is uninformative exactly where a
      // name exists to be shown; a collective makes no singular claim to be
      // uninformative about, so "your other devices" stays.
      for (final sentence in _everySentence()) {
        for (final phrase in syncHealthBannedDeviceReferences) {
          expect(
            sentence.text.toLowerCase().contains(phrase),
            isFalse,
            reason: '"${sentence.where}" points at an unnamed device: '
                '${sentence.text}',
          );
        }
      }
    });

    test('E3 no sentence speaks in the Jeeves register', () {
      // The first surface that deliberately opts out. A future contributor
      // reintroducing the persona here has to delete this test to do it.
      for (final sentence in _everySentence()) {
        for (final marker in syncHealthBannedVoiceMarkers) {
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
}
