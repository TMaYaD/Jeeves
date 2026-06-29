/// The overridable wall-clock seam, shared by every Provider that needs a
/// reactive "what time is it" source — the Nudge module's time-based Triggers
/// (`nudge_clock_provider.dart`) and the Weekly Review due predicate
/// (`periodic_review_settings_provider.dart`).
///
/// Lives in its own file so both can depend on it without an import cycle.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The overridable wall-clock source. Returns the current instant each call.
///
/// Production reads `DateTime.now()`. Tests override this with a closure over a
/// mutable instant so a boundary crossing can be simulated without real
/// wall-time passing:
///
/// ```dart
/// var now = DateTime(2026, 6, 29, 17, 59);
/// final container = ProviderContainer(overrides: [
///   clockProvider.overrideWithValue(() => now),
/// ]);
/// // advance `now`, then invalidate the dependent Provider to re-evaluate.
/// ```
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
