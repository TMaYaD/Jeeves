import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// Call once before any test that uses [NativeDatabase].
///
/// On Linux CI/dev hosts the dev package often isn't installed, so
/// `libsqlite3.so` (unversioned) is missing while `libsqlite3.so.0` exists.
/// This override points the sqlite3 package at the versioned library.
void configureSqliteForTests() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => DynamicLibrary.open('libsqlite3.so.0'),
    );
  }
}
