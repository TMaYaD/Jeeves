/// What the vault reports about itself.
///
/// The shared plugin health, plus the things only the vault knows: how many
/// pages in the folder the app could not use, how many it could not take, and
/// whether the folder could be reached at all. Nothing reads these yet — the
/// drawer indicator folds plugin health in later — so a broken vault is
/// reported and logged, and stays quiet on screen.
library;

import '../host/change.dart';

class VaultHealth extends PluginHealth {
  const VaultHealth({
    super.pendingChangeCount,
    super.lastSyncedAt,
    this.unreadablePageCount = 0,
    this.untakenPageCount = 0,
    this.folderReachable = true,
  });

  /// Pages the last read pass could not read or parse, and left alone. A page
  /// the app cannot read is a person's data it has not seen: it is never
  /// written over, and it is counted here so the failure is news rather than
  /// silence.
  final int unreadablePageCount;

  /// Pages the last read pass could not take into the host, and left alone.
  /// The host refused what the page says, so the app does not have it: the
  /// page keeps its content, the next pass takes it again, and the count says
  /// so rather than leaving the app quietly behind the folder.
  final int untakenPageCount;

  /// Whether the folder could be reached. False means a folder could not be
  /// listed, so nothing in it could be carried either way. The other folders
  /// were still read.
  final bool folderReachable;
}
