/// The passphrase policy: what gets generated, and when a warning is owed.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/eff_large_wordlist.dart';
import 'package:jeeves/sync/passphrase_policy.dart';

void main() {
  const policy = PassphrasePolicy();

  group('the wordlist', () {
    test('is the EFF large list, whole and unique', () {
      // 7776 = 6^5 is not a detail: it is what makes each word exactly five
      // dice rolls and the entropy arithmetic below exact.
      expect(effLargeWordlist.length, 7776);
      expect(effLargeWordlist.toSet().length, 7776);
      expect(effLargeWordlist.first, 'abacus');
      expect(effLargeWordlist.last, 'zoom');
      expect(
        effLargeWordlist.every((word) => RegExp(r'^[a-z-]+$').hasMatch(word)),
        isTrue,
      );
    });
  });

  group('generation', () {
    test('draws the configured number of words', () {
      final passphrase = policy.generate(random: Random(7));
      expect(passphrase.split(passphraseWordSeparator).length,
          defaultPassphraseWordCount);
      expect(
        passphrase.split(passphraseWordSeparator).every(effLargeWordlist.contains),
        isTrue,
      );
    });

    test('clears the warning threshold with room to spare', () {
      // ~77.5 bits against a ~70-bit threshold. If the wordlist or the word
      // count ever shrank, this is what would notice.
      expect(policy.generatedBits, greaterThan(passphraseWarningBitsThreshold));
      expect(policy.generatedBits, closeTo(77.5, 0.1));

      final strength = policy.strengthOfGenerated();
      expect(strength.isGenerated, isTrue);
      expect(strength.isBelowWarningThreshold, isFalse);
      expect(strength.warning, isNull);
    });

    test('two draws differ', () {
      expect(policy.generate(random: Random(1)),
          isNot(policy.generate(random: Random(2))));
    });
  });

  group('estimating a typed passphrase', () {
    test('a re-typed generated passphrase is not called weak', () {
      // The whole reason the word estimate exists: a user copying the phrase
      // Jeeves gave them must not be warned about it.
      final generated = policy.generate(random: Random(11));
      final strength = policy.estimate(generated);
      expect(strength.isGenerated, isFalse);
      expect(strength.isBelowWarningThreshold, isFalse);
      expect(strength.warning, isNull);
    });

    test('a short one is warned about, in the proposal\'s own terms', () {
      final strength = policy.estimate('hunter2');
      expect(strength.isBelowWarningThreshold, isTrue);
      // The warning says what is actually true: this is the encryption ceiling
      // and nobody can reset it.
      expect(strength.warning, contains('ceiling'));
      expect(strength.warning, contains('nobody'));
    });

    test('an empty passphrase has no entropy', () {
      expect(policy.estimate('   ').estimatedBits, 0);
    });

    test('the lower of the two estimates wins', () {
      // Four dictionary words is ~51.7 bits as words, and rather more as
      // characters. A passphrase that looks strong by one measure and weak by
      // the other is treated as weak.
      final fourWords =
          effLargeWordlist.take(4).join(passphraseWordSeparator);
      expect(policy.estimate(fourWords).estimatedBits, closeTo(51.7, 0.1));
      expect(policy.estimate(fourWords).isBelowWarningThreshold, isTrue);
    });

    test('a long mixed-class passphrase clears the threshold', () {
      expect(
        policy.estimate('Tr0ub4dor&3-Xk9!qZ_vLm7#Ws2').isBelowWarningThreshold,
        isFalse,
      );
    });

    test('a shorter wordlist means fewer bits per word', () {
      const tiny = PassphrasePolicy(wordlist: ['alpha', 'beta'], wordCount: 6);
      expect(tiny.bitsPerWord, 1.0);
      expect(tiny.generatedBits, 6.0);
      expect(tiny.strengthOfGenerated().isBelowWarningThreshold, isTrue);
    });
  });
}
