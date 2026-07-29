// Platform-adaptive opener for the reseed verification's throwaway stores.
//
// **Cutover tooling — removed by #556.**
//
// The same conditional-export rule `sync/sync_store.dart` follows, and for the
// same reason: opening a native database is `dart:io` code, and the app declares
// web as a platform, so a direct `package:drift/native.dart` import here would
// break the web build. The permanent `sync_store*.dart` pair is left alone —
// these stores exist for one throwaway verification and go with it.
//
//   - dart:io available: reseed_scratch_store_io.dart   → in-memory native stores
//   - otherwise (web):   reseed_scratch_store_stub.dart → throws UnsupportedError
export 'reseed_scratch_store_stub.dart'
    if (dart.library.io) 'reseed_scratch_store_io.dart';
