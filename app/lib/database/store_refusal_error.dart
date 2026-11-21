/// The refusal a build makes when it cannot open a local store.
///
/// Two reasons, and to the app they mean the same thing: the store was
/// written by a newer build, or the build could not read what the store
/// carries. Either way this build opens neither store and leaves both files
/// exactly as it found them.
///
/// **It is an [Error] on purpose.** A refusal is final: a store written by a
/// newer build does not become readable by waiting, and a file that cannot be
/// read does not become readable by waiting either. Riverpod retries a
/// provider that failed with an `Exception`, so the refusal would reach its
/// caller tens of seconds late, and inside a widget test — where the retry
/// timer is fake — it would never arrive at all. Riverpod does not retry a
/// failure that is an `Error`, which is what a refusal is.
///
/// Its own file so the store classes can throw it without importing the module
/// that reads the files: that module needs the store classes' schema versions,
/// and an import cycle between them would leave the rule in neither.
library;

/// The refusal a build makes when a local store cannot be opened.
///
/// Sealed, because the two reasons below are the only ones there are, and the
/// app's screens tell them apart.
sealed class StoreRefusalError extends Error {
  StoreRefusalError({required this.storeName});

  /// Which of the two stores the file belongs to: the domain read model, or
  /// the op log.
  final String storeName;
}

/// The store was written by a newer build.
///
/// Thrown in two places, and they mean the same thing:
///   - by a store's own migration path, when it is opened against a file whose
///     schema version is above the one this build understands;
///   - by the startup gate, which reads both store files before anything opens
///     them.
class StoreVersionTooNewError extends StoreRefusalError {
  StoreVersionTooNewError({
    required super.storeName,
    required this.storedVersion,
    required this.supportedVersion,
  });

  /// The schema version the file on disk carries.
  final int storedVersion;

  /// The highest schema version this build understands.
  final int supportedVersion;

  @override
  String toString() =>
      'The $storeName was written by a newer version of Jeeves: it carries '
      'schema version $storedVersion, and this build understands up to '
      '$supportedVersion. Nothing was changed.';
}

/// The store's schema version could not be read.
///
/// **A file that cannot be opened is not a file that is not there.** It says
/// nothing about the schema it carries: it may well be a store a newer build
/// wrote, and this build would not know. So the check is inconclusive, and an
/// inconclusive check is a refusal — the build opens neither store.
class StoreVersionUnreadableError extends StoreRefusalError {
  StoreVersionUnreadableError({
    required super.storeName,
    required this.reason,
  });

  /// Why the file could not be read.
  final String reason;

  @override
  String toString() =>
      'The $storeName could not be read: $reason. Nothing was changed.';
}
