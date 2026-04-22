/// Call once before any test that uses [NativeDatabase].
///
/// sqlite3 >=3.0 loads the native library via build hooks rather than
/// runtime [DynamicLibrary] overrides, so no manual path fixup is needed.
// ignore_for_file: avoid_returning_null_for_void
void configureSqliteForTests() {}
