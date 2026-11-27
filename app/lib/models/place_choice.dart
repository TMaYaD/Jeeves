/// The Place a user chose in the place picker (issue #1078).
///
/// The picker writes nothing: it hands back what the user chose, and the
/// surface that opened it applies the choice. A named Place carries its id
/// and its name; a one-time pin carries its area and the short name it may
/// carry.
library;

import 'place_area.dart';

/// What the user chose in the place picker.
sealed class PlaceChoice {
  const PlaceChoice();
}

/// The user cleared the Place: the Action carries none.
final class ClearPlaceChoice extends PlaceChoice {
  const ClearPlaceChoice();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ClearPlaceChoice;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'ClearPlaceChoice()';
}

/// A Place to put on an Action: a named Place, or a one-time pin.
sealed class ActionPlaceDraft extends PlaceChoice {
  const ActionPlaceDraft();
}

/// One of the user's named Places.
final class NamedPlaceDraft extends ActionPlaceDraft {
  const NamedPlaceDraft(this.placeId, this.name);

  /// The named Place's id — the row the Action points at.
  final String placeId;

  /// The name to show for it.
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NamedPlaceDraft &&
          other.placeId == placeId &&
          other.name == name;

  @override
  int get hashCode => Object.hash(placeId, name);

  @override
  String toString() => 'NamedPlaceDraft(placeId: $placeId, name: $name)';
}

/// A one-time pin: a Place of that one Action, never listed anywhere.
final class PinDraft extends ActionPlaceDraft {
  const PinDraft({required this.area, this.name});

  /// Where the pin is, and how far from that point it reaches.
  final PlaceArea area;

  /// The short name the pin may carry; null when it has none.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PinDraft && other.area == area && other.name == name;

  @override
  int get hashCode => Object.hash(area, name);

  @override
  String toString() => 'PinDraft(area: $area, name: $name)';
}

/// The label to show for a Place: the Place's own name, or "Pin" for a
/// one-time pin that carries none.
///
/// The one rule both places that name a Place go by — the Outcome's Place
/// chip and the clarify card's — so the two never disagree about what a
/// pin reads as.
String placeNameLabel(String? name) {
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return 'Pin';
  return trimmed;
}

/// The label to show for the Place a user chose: a named Place by its name, a
/// one-time pin by the short name it may carry, or "Pin" when it has none.
String placeDraftLabel(ActionPlaceDraft place) => placeNameLabel(
      switch (place) {
        NamedPlaceDraft(:final name) => name,
        PinDraft(:final name) => name,
      },
    );
