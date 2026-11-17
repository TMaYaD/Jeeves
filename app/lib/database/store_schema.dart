/// The two local stores' schema versions, and the refusal a build makes when
/// one of them was written by a newer build.
///
/// **A build that cannot read a store must not touch it.** The stores hold
/// everything the user has; a build that meets a file it does not understand
/// leaves that file exactly as it found it — no migration, no re-projection,
/// no sync, no write — and says so on the screen instead of opening it.
///
/// The versions are read from the files themselves (`PRAGMA user_version`),
/// before anything opens them, because the two files have to be judged
/// together: a build that can read the op log but not the read model would
/// project reduced state into a read model it cannot migrate, and one that can
/// read the read model but not the op log would keep syncing from a log it
/// does not understand. So a build that cannot read one of them reads neither.
///
/// The store classes carry their own refusal as a backstop, for the case where
/// this read does not happen — the file turns out to be unreadable, or it is
/// written between the read and the open.
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../sync/sync_database.dart';
import 'gtd_database.dart';
import 'store_version_error.dart';

// The reader itself is platform-dependent: `store_schema_io.dart` on a device,
// `store_schema_stub.dart` on the web. The conditional import is the same rule
// `database/domain_store.dart` follows.
import 'store_schema_stub.dart' if (dart.library.io) 'store_schema_io.dart';

/// The schema versions the two local store files carry on disk.
class LocalStoreVersions {
  const LocalStoreVersions({
    this.domainStoreVersion,
    this.syncStoreVersion,
  });

  /// The domain read model's schema version, or null when there is no file.
  final int? domainStoreVersion;

  /// The op log's schema version, or null when there is no file.
  final int? syncStoreVersion;

  /// The first of the two stores this build cannot read, or null when it can
  /// read both.
  ///
  /// A file with no version at all is one this build can read: a store the app
  /// has yet to create is one it is free to write.
  StoreVersionTooNewError? get refusal {
    final domain = domainStoreVersion;
    if (domain != null && domain > GtdDatabase.supportedSchemaVersion) {
      return StoreVersionTooNewError(
        storeName: 'domain read model',
        storedVersion: domain,
        supportedVersion: GtdDatabase.supportedSchemaVersion,
      );
    }
    final sync = syncStoreVersion;
    if (sync != null && sync > SyncDatabase.supportedSchemaVersion) {
      return StoreVersionTooNewError(
        storeName: 'op log',
        storedVersion: sync,
        supportedVersion: SyncDatabase.supportedSchemaVersion,
      );
    }
    return null;
  }
}

/// The two store files' schema versions, in the app documents directory.
///
/// A version that cannot be read is reported as no version at all: the gate
/// then lets the app start, and the store's own migration path is the backstop
/// that refuses a file it cannot read.
Future<LocalStoreVersions> readLocalStoreVersions() async {
  try {
    final raw = await readStoreFileVersions();
    return LocalStoreVersions(
      domainStoreVersion: raw.domainStoreVersion,
      syncStoreVersion: raw.syncStoreVersion,
    );
  } on Object catch (error) {
    debugPrint('local stores: the schema versions could not be read — $error');
    return const LocalStoreVersions();
  }
}

/// The two store files' schema versions, in [directoryPath].
///
/// The same read over an explicit directory, so it can be exercised against a
/// temp directory instead of only on a device.
Future<LocalStoreVersions> readLocalStoreVersionsIn(
    String directoryPath) async {
  try {
    final raw = await readStoreFileVersionsIn(directoryPath);
    return LocalStoreVersions(
      domainStoreVersion: raw.domainStoreVersion,
      syncStoreVersion: raw.syncStoreVersion,
    );
  } on Object catch (error) {
    debugPrint('local stores: the schema versions could not be read — $error');
    return const LocalStoreVersions();
  }
}
