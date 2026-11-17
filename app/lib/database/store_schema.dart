/// The two local stores' schema versions, and the refusal a build makes when
/// one of them was written by a newer build — or when one of them could not
/// be read at all.
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
/// **A file it cannot open is not a file that is not there.** An unreadable
/// file is as unknown as a newer one — maybe more so — so the check is
/// inconclusive, and an inconclusive check refuses exactly as a newer file
/// does.
///
/// The store classes carry their own refusal as a backstop, for the case where
/// this read does not happen — the file turns out to be unreadable, or it is
/// written between the read and the open.
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../sync/sync_database.dart';
import 'gtd_database.dart';
import 'store_file_probe.dart';
import 'store_refusal_error.dart';

// The reader itself is platform-dependent: `store_schema_io.dart` on a device,
// `store_schema_stub.dart` on the web. The conditional import is the same rule
// `database/domain_store.dart` follows.
import 'store_schema_stub.dart' if (dart.library.io) 'store_schema_io.dart';

/// The schema versions the two local store files carry on disk.
class LocalStoreVersions {
  const LocalStoreVersions({
    required this.domainStore,
    required this.syncStore,
  });

  /// No store file at all: nothing to read, nothing to refuse.
  const LocalStoreVersions.absent()
      : domainStore = const StoreFileProbe.absent(),
        syncStore = const StoreFileProbe.absent();

  /// What the probe found in the domain read model's file.
  final StoreFileProbe domainStore;

  /// What the probe found in the op log's file.
  final StoreFileProbe syncStore;

  /// The domain read model's schema version, when its file could be read.
  int? get domainStoreVersion => domainStore.version;

  /// The op log's schema version, when its file could be read.
  int? get syncStoreVersion => syncStore.version;

  /// The store written by a newer build, if either is.
  ///
  /// A file with no version at all is one this build can read: a store the app
  /// has yet to create is one it is free to write.
  StoreVersionTooNewError? get tooNew {
    final domain = domainStore.version;
    if (domain != null && domain > GtdDatabase.supportedSchemaVersion) {
      return StoreVersionTooNewError(
        storeName: 'domain read model',
        storedVersion: domain,
        supportedVersion: GtdDatabase.supportedSchemaVersion,
      );
    }
    final sync = syncStore.version;
    if (sync != null && sync > SyncDatabase.supportedSchemaVersion) {
      return StoreVersionTooNewError(
        storeName: 'op log',
        storedVersion: sync,
        supportedVersion: SyncDatabase.supportedSchemaVersion,
      );
    }
    return null;
  }

  /// The store whose version could not be read, if either is.
  ///
  /// **An unreadable file is not an absent one.** A file the app cannot open
  /// says nothing about the schema it carries — it may be a store a newer
  /// build wrote, and this build would not know. So the check is inconclusive,
  /// and an inconclusive check refuses: this build opens neither store.
  StoreVersionUnreadableError? get unreadable {
    if (domainStore.isUnreadable) {
      return StoreVersionUnreadableError(
        storeName: 'domain read model',
        reason: domainStore.unreadableReason!,
      );
    }
    if (syncStore.isUnreadable) {
      return StoreVersionUnreadableError(
        storeName: 'op log',
        reason: syncStore.unreadableReason!,
      );
    }
    return null;
  }

  /// The refusal this build makes, if it makes one: it opens neither store.
  ///
  /// A store written by a newer build comes first. It is a fact about the
  /// data, it is the one the user can act on, and it is the reason the
  /// blocking screen exists.
  StoreRefusalError? get refusal => tooNew ?? unreadable;
}

/// The two store files' schema versions, in the app documents directory.
///
/// A file that is not there is reported as absent, and a file that cannot be
/// read is reported as unreadable: the gate keeps both stores closed on the
/// second as firmly as on the first.
Future<LocalStoreVersions> readLocalStoreVersions() async {
  try {
    final probes = await readStoreFileProbes();
    return LocalStoreVersions(
      domainStore: probes.domainStore,
      syncStore: probes.syncStore,
    );
  } on UnsupportedError {
    // This platform has no local store at all (web): there is nothing to
    // read, so there is nothing to refuse and nothing to protect.
    return const LocalStoreVersions.absent();
  } on Object catch (error) {
    // The check itself failed. We do not know what the files carry, so the
    // check is inconclusive, and an inconclusive check refuses.
    debugPrint('local stores: the schema versions could not be read — $error');
    return LocalStoreVersions(
      domainStore: StoreFileProbe.unreadable('$error'),
      syncStore: StoreFileProbe.unreadable('$error'),
    );
  }
}

/// The two store files' schema versions, in [directoryPath].
///
/// The same read over an explicit directory, so it can be exercised against a
/// temp directory instead of only on a device.
Future<LocalStoreVersions> readLocalStoreVersionsIn(
    String directoryPath) async {
  try {
    final probes = await readStoreFileProbesIn(directoryPath);
    return LocalStoreVersions(
      domainStore: probes.domainStore,
      syncStore: probes.syncStore,
    );
  } on UnsupportedError {
    return const LocalStoreVersions.absent();
  } on Object catch (error) {
    debugPrint('local stores: the schema versions could not be read — $error');
    return LocalStoreVersions(
      domainStore: StoreFileProbe.unreadable('$error'),
      syncStore: StoreFileProbe.unreadable('$error'),
    );
  }
}
