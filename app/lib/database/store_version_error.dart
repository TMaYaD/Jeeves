/// The refusal a build makes when a local store was written by a newer build.
///
/// Thrown in two places, and they mean the same thing:
///   - by a store's own migration path, when it is opened against a file whose
///     schema version is above the one this build understands;
///   - by the startup gate, which reads both store files before anything opens
///     them.
///
/// Its own file so the store classes can throw it without importing the module
/// that reads the files: that module needs the store classes' schema versions,
/// and an import cycle between them would leave the rule in neither.
library;

class StoreVersionTooNewError implements Exception {
  const StoreVersionTooNewError({
    required this.storeName,
    required this.storedVersion,
    required this.supportedVersion,
  });

  /// Which of the two stores the file belongs to: the domain read model, or
  /// the op log.
  final String storeName;

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
