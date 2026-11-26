/// The hash the local notification ids and signatures are built from.
///
/// One hash for every kind of local notification, so a Habit's id cannot be
/// mistaken for an Outcome's and a signature cannot be read as an id.
library;

import 'dart:convert';

/// The FNV-1a hash of [text] over its UTF-8 bytes, as a 32-bit unsigned
/// integer.
///
/// Stable across runs, unlike `String.hashCode`, which differs between runs
/// — an id or a signature built from it has to survive a restart.
int fnv1a32(String text) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
