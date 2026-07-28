/// What a recovery passphrase has to be, and how strong the one you chose is.
///
/// The passphrase is the ceiling on the account's end-to-end encryption
/// (proposal § Identity and keys): Root lives behind it and nothing else
/// protects the escrow. So the default is generated, not typed — six words from
/// the EFF large list, ~77 bits — and a user-chosen override is allowed only
/// behind an entropy estimate and an explicit warning about what it costs.
///
/// Pure functions. The screens are #553's; the numbers and the copy triggers
/// are here so they can be tested without one.
library;

import 'dart:math';

import 'eff_large_wordlist.dart';

/// Six words from a 7776-word list: 6 x log2(7776) ~ 77.5 bits.
///
/// not configurable per call: this is the security floor of the whole account,
/// not a per-user preference. Raising it is a product decision, made here.
const int defaultPassphraseWordCount = 6;

/// The separator between generated words. Spaces read better than hyphens when
/// a user has to copy one off a screen onto paper.
const String passphraseWordSeparator = ' ';

/// Below this, the warning is not advisory.
///
/// ~70 bits is roughly where an offline attacker with commodity hardware stops
/// being hypothetical, given the Argon2id floor in `recovery_escrow.dart`. A
/// generated six-word passphrase clears it with room to spare; most typed ones
/// do not.
const double passphraseWarningBitsThreshold = 70.0;

/// How strong a passphrase is, and whether to say so loudly.
class PassphraseStrength {
  const PassphraseStrength({required this.estimatedBits, required this.isGenerated});

  /// A *lower bound* estimate, in bits. For a generated passphrase this is
  /// exact — we know the alphabet and the draw. For a typed one it is a
  /// character-class heuristic, which flatters anything with a pattern in it;
  /// that is the honest direction to be wrong in only because the copy that
  /// goes with it never promises safety, just refuses to promise danger.
  final double estimatedBits;

  /// True when Jeeves drew the passphrase rather than the user typing one.
  final bool isGenerated;

  bool get isBelowWarningThreshold => estimatedBits < passphraseWarningBitsThreshold;

  /// The warning a screen must show, or null when there is nothing to say.
  ///
  /// The wording is the proposal's own claim, not a scare: passphrase entropy
  /// *is* the encryption ceiling, and no amount of server-side care changes it.
  String? get warning => isBelowWarningThreshold
      ? 'This passphrase is the ceiling on your encryption: everything Jeeves '
          'syncs is only as private as it is. Anyone who guesses it can read '
          'your data, and nobody — including us — can reset it for you.'
      : null;

  @override
  String toString() =>
      'PassphraseStrength(${estimatedBits.toStringAsFixed(1)} bits, '
      'generated: $isGenerated)';
}

/// Generates and rates recovery passphrases.
class PassphrasePolicy {
  const PassphrasePolicy({
    this.wordlist = effLargeWordlist,
    this.wordCount = defaultPassphraseWordCount,
  });

  final List<String> wordlist;
  final int wordCount;

  /// Bits per word for this list, exactly.
  double get bitsPerWord => log(wordlist.length) / ln2;

  /// The entropy of a passphrase this policy generates.
  double get generatedBits => bitsPerWord * wordCount;

  /// Draw a fresh passphrase.
  ///
  /// [random] defaults to [Random.secure]; a seeded one is for tests only, and
  /// naming it in the signature is what keeps that visible at the call site.
  String generate({Random? random}) {
    final entropy = random ?? Random.secure();
    return List<String>.generate(
      wordCount,
      (_) => wordlist[entropy.nextInt(wordlist.length)],
    ).join(passphraseWordSeparator);
  }

  /// The strength of a passphrase this policy generated. Exact, by construction.
  PassphraseStrength strengthOfGenerated() =>
      PassphraseStrength(estimatedBits: generatedBits, isGenerated: true);

  /// Estimate the strength of a passphrase the user typed.
  ///
  /// Two estimates, and the *lower* wins:
  ///
  /// - **As words**, if every token is in the wordlist: `tokens x bitsPerWord`.
  ///   This is the one that matters, because a user re-typing a generated
  ///   passphrase must not be told it is weak.
  /// - **As characters**: `length x log2(alphabet)` over the character classes
  ///   actually used. Deliberately crude — a real strength estimator is a
  ///   dependency (zxcvbn and a dictionary), and the decision here is only
  ///   whether to show a warning.
  ///
  /// Taking the lower of the two means a passphrase that looks strong by one
  /// measure and weak by the other is treated as weak.
  PassphraseStrength estimate(String passphrase) {
    final trimmed = passphrase.trim();
    if (trimmed.isEmpty) {
      return const PassphraseStrength(estimatedBits: 0, isGenerated: false);
    }
    final characterBits = trimmed.length * (log(_alphabetSize(trimmed)) / ln2);
    final tokens = trimmed.split(RegExp(r'\s+'));
    final wordBits = tokens.every(_wordSet.contains) ? tokens.length * bitsPerWord : null;
    return PassphraseStrength(
      estimatedBits: wordBits == null ? characterBits : min(wordBits, characterBits),
      isGenerated: false,
    );
  }

  Set<String> get _wordSet => _wordSetCache[wordlist] ??= wordlist.toSet();

  static final Map<List<String>, Set<String>> _wordSetCache = {};

  static int _alphabetSize(String passphrase) {
    var size = 0;
    if (passphrase.contains(RegExp('[a-z]'))) size += 26;
    if (passphrase.contains(RegExp('[A-Z]'))) size += 26;
    if (passphrase.contains(RegExp('[0-9]'))) size += 10;
    if (passphrase.contains(RegExp(r'\s'))) size += 1;
    if (passphrase.contains(RegExp(r'[^A-Za-z0-9\s]'))) size += 33;
    // A single repeated character has an alphabet of one, and log2(1) is zero.
    // Two is the floor that keeps the estimate a number rather than a nothing.
    return size < 2 ? 2 : size;
  }
}
