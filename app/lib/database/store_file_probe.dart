/// What the startup probe found in one store file.
///
/// Three states, and the difference between the last two is the whole point.
/// A file that is not there is a store the app has yet to create, and one it
/// is free to write. A file that is there but cannot be read says nothing
/// about the schema it carries — it may well be a store a newer build wrote,
/// and this build would not know — so it is a refusal, not an absence.
///
/// Pure Dart, no Flutter import: the probe is a value, and the platform's
/// reader is the only thing that knows how to produce one.
library;

/// What the probe found in one store file.
class StoreFileProbe {
  /// There is no file: the app has yet to create this store.
  const StoreFileProbe.absent()
      : version = null,
        unreadableReason = null;

  /// The file was read, and carries this schema version.
  const StoreFileProbe.readable(int this.version) : unreadableReason = null;

  /// The file is there, but could not be read: the check is inconclusive.
  const StoreFileProbe.unreadable(String this.unreadableReason) : version = null;

  /// The schema version the file carries, when it could be read.
  final int? version;

  /// Why the file could not be read, when it could not.
  final String? unreadableReason;

  /// Whether there is no file at all.
  bool get isAbsent => version == null && unreadableReason == null;

  /// Whether the file is there but could not be read.
  bool get isUnreadable => unreadableReason != null;
}
