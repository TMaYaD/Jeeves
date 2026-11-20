/// Which folder a vault setting names, and how to reach it.
///
/// One setting, one string: a tree URI on Android, an absolute path elsewhere.
/// The scheme is what tells them apart — a `content://` URI is a document tree
/// the system picker granted, anything else is a directory on this device.
library;

import 'android_vault_folder.dart';
import 'vault_folder.dart';
import 'vault_folder_impl.dart';

/// The scheme the system folder picker returns.
const String androidTreeUriScheme = 'content://';

/// The [VaultFolder] a vault setting names.
///
/// A tree URI is Android's; anything else is a path on this device. The path
/// half throws on a platform with no directories (see `vault_folder_stub.dart`),
/// which is why the vault's tile is not shown on the web.
VaultFolder openVaultFolder(String reference) {
  if (reference.startsWith(androidTreeUriScheme)) {
    return AndroidVaultFolder(reference);
  }
  return openLocalVaultFolder(reference);
}
