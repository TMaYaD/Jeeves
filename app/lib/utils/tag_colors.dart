/// Pastel text-color palette and helpers for tag rendering.
///
/// Colors are chosen to be readable as text on both light backgrounds
/// (white drawer, white cards) and are sufficiently distinguishable from
/// each other for a tag cloud of ~16 items.
library;

import 'package:flutter/material.dart';

/// 16 pastel-text colors drawn from Tailwind CSS 700–900 shades.
///
/// These are stored / compared as hex strings via [tagColorToHex] /
/// [tagColorFromHex].  The palette index is frozen once written to the
/// database, so renaming a tag never changes its color.
const List<Color> kTagPalette = [
  Color(0xFF1D4ED8), // blue-700
  Color(0xFF7E22CE), // purple-700
  Color(0xFF047857), // emerald-700
  Color(0xFFC2410C), // orange-700
  Color(0xFFBE185D), // pink-700
  Color(0xFF4338CA), // indigo-700
  Color(0xFF0F766E), // teal-700
  Color(0xFF92400E), // amber-800
  Color(0xFF065F46), // green-800
  Color(0xFF9D174D), // rose-800
  Color(0xFF1E3A8A), // blue-900
  Color(0xFF5B21B6), // violet-700
  Color(0xFF166534), // green-700
  Color(0xFF7C2D12), // orange-900
  Color(0xFF831843), // pink-900
  Color(0xFF134E4A), // teal-900
];

/// Returns the palette index for [name] using a simple but stable hash.
///
/// Deterministic: any two installs hashing the same name get the same index.
int tagPaletteIndexForName(String name) {
  if (name.isEmpty) return 0;
  final hash = name.runes.fold(0, (prev, c) => (prev * 31 + c) & 0x7FFFFFFF);
  return hash % kTagPalette.length;
}

/// Derives the default text color for [name] from the palette.
Color tagColorForName(String name) =>
    kTagPalette[tagPaletteIndexForName(name)];

/// Serializes [color] to a `#RRGGBB` hex string for database storage.
String tagColorToHex(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

/// Parses a `#RRGGBB` or `RRGGBB` hex string back to a [Color].
///
/// Returns the first palette entry as a fallback for malformed values.
Color tagColorFromHex(String hex) {
  final clean = hex.startsWith('#') ? hex.substring(1) : hex;
  if (clean.length != 6) return kTagPalette.first;
  final value = int.tryParse(clean, radix: 16);
  if (value == null) return kTagPalette.first;
  return Color(0xFF000000 | value);
}

/// Resolves the display color for [tag.color]: parses stored hex if present,
/// otherwise derives from the tag name.
Color resolvedTagColor({required String name, String? storedHex}) {
  if (storedHex != null && storedHex.isNotEmpty) {
    return tagColorFromHex(storedHex);
  }
  return tagColorForName(name);
}
