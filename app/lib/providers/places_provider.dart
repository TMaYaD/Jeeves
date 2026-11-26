/// The user's named Places (issue #55).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/place_dao.dart' show NamedPlaceWithUse;
import 'database_provider.dart';

/// The user's named places, each with the number of live Actions that use it,
/// most recently used first.
final namedPlacesWithUseCountProvider =
    StreamProvider<List<NamedPlaceWithUse>>((ref) {
  return ref.watch(databaseProvider).placeDao.watchNamedPlacesWithUseCount();
});
