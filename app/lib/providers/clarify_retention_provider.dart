/// The app-wide [ClarifyRetention] store.
///
/// A plain `Provider` holding a plain object: nothing here publishes state, so
/// stashing a keystroke rebuilds nothing. The ceremony step hosts read it once
/// and hand it to [ClarifyCard] as a constructor argument, which is what lets
/// the card reach it from `dispose()` — see [ClarifyRetention] for why that
/// matters.
///
/// Not `autoDispose`: the store must outlive the card that stashed into it,
/// which is the whole point.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/clarify_retention.dart';

final clarifyRetentionProvider =
    Provider<ClarifyRetention>((ref) => ClarifyRetention());
