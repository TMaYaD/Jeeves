/// How far an import has got, and how much there is to do.
///
/// **A report is the difference between an import that is working and an
/// import that has stopped.** A file with thousands of records takes minutes
/// — every record is written and described on the op log, and signing is not
/// cheap — and a screen that cannot say where it is leaves the user watching
/// an unchanging spinner, deciding whether to wait or to give up. The two
/// questions a user actually has during an import are "how far along is it"
/// and "is it still going", and this is the answer to the first.
library;

/// One import's progress: how many records it has finished with, and how many
/// the file carried in all.
class ImportProgress {
  const ImportProgress({required this.processedRows, required this.totalRows});

  /// Records the import has finished with — taken, or refused and named.
  final int processedRows;

  /// Records the file carried in all.
  final int totalRows;

  /// How far along the import is, from 0 to 1.
  ///
  /// A file with no records is finished the moment it starts, so it reports
  /// 1 rather than dividing by zero.
  double get fraction {
    if (totalRows == 0) return 1;
    final value = processedRows / totalRows;
    return value.clamp(0.0, 1.0);
  }
}

/// Called as an import advances.
///
/// Optional throughout: an import with nobody listening simply reports to
/// nobody, which is why this is a callback and not a stream — a stream would
/// have to be closed by every caller, and a caller that forgets leaks one.
typedef ImportProgressCallback = void Function(ImportProgress progress);
