/// `folder.json` and `member.json`: the two small files in an op-log folder that
/// are not segments.
///
/// Both come from a place other apps and the file syncer can write to, so they
/// are parsed with a size limit, strict types and an exact key set: an unknown or
/// malformed field is refused rather than guessed at.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../envelope.dart';

const String folderFormatName = 'jeeves-op-log-folder';
const int folderFormatVersion = 1;
const int memberFileVersion = 1;

/// Neither file is ever larger than this; a bigger one is refused unread.
const int maxMetadataFileBytes = 4096;
const int maxDeviceLabelLength = 64;

const String folderFileName = 'folder.json';
const String memberFileName = 'member.json';
const String opsDirectoryName = 'ops';

/// Why a folder's metadata could not be used. The message is for the person.
class FolderMetadataRefusal implements Exception {
  const FolderMetadataRefusal(this.message);
  final String message;

  @override
  String toString() => message;
}

Map<String, Object?> _parseStrictObject(Uint8List bytes, Set<String> keys, String what) {
  if (bytes.length > maxMetadataFileBytes) {
    throw FolderMetadataRefusal('$what is larger than $maxMetadataFileBytes bytes.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw FolderMetadataRefusal('$what is not readable JSON.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw FolderMetadataRefusal('$what is not a JSON object.');
  }
  if (decoded.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(decoded.keys.toSet()).isNotEmpty) {
    throw FolderMetadataRefusal('$what does not have exactly the expected fields.');
  }
  return decoded;
}

class FolderFile {
  const FolderFile({required this.folderId});

  final String folderId;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'format': folderFormatName,
        'version': folderFormatVersion,
        'folder_id': folderId,
      })));

  static FolderFile parse(Uint8List bytes) {
    final json = _parseStrictObject(bytes, {'format', 'version', 'folder_id'}, 'folder.json');
    if (json['format'] != folderFormatName) {
      throw const FolderMetadataRefusal('This folder is not a Jeeves sync folder.');
    }
    if (json['version'] != folderFormatVersion) {
      throw const FolderMetadataRefusal(
          'This folder was made by a different version of Jeeves.');
    }
    final folderId = json['folder_id'];
    if (folderId is! String || !isCanonicalUuid(folderId)) {
      throw const FolderMetadataRefusal('folder.json has no valid folder id.');
    }
    return FolderFile(folderId: folderId);
  }
}

class MemberFile {
  const MemberFile({
    required this.folderId,
    required this.memberId,
    required this.signPublicKey,
    required this.deviceLabel,
  });

  final String folderId;
  final String memberId;
  final Uint8List signPublicKey;
  final String deviceLabel;

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'version': memberFileVersion,
        'folder_id': folderId,
        'member_id': memberId,
        'sign_public_key': base64Encode(signPublicKey),
        'device_label': deviceLabel,
      })));

  static MemberFile parse(Uint8List bytes) {
    final json = _parseStrictObject(
      bytes,
      {'version', 'folder_id', 'member_id', 'sign_public_key', 'device_label'},
      'member.json',
    );
    if (json['version'] != memberFileVersion) {
      throw const FolderMetadataRefusal('member.json is from a different version of Jeeves.');
    }
    final folderId = json['folder_id'];
    final memberId = json['member_id'];
    final key = json['sign_public_key'];
    final label = json['device_label'];
    if (folderId is! String || !isCanonicalUuid(folderId)) {
      throw const FolderMetadataRefusal('member.json has no valid folder id.');
    }
    if (memberId is! String || !isCanonicalUuid(memberId)) {
      throw const FolderMetadataRefusal('member.json has no valid member id.');
    }
    if (label is! String || label.isEmpty || label.length > maxDeviceLabelLength) {
      throw const FolderMetadataRefusal('member.json has no valid device label.');
    }
    final Uint8List keyBytes;
    try {
      keyBytes = base64Decode(key is String ? key : '');
    } on FormatException {
      throw const FolderMetadataRefusal('member.json has an unreadable key.');
    }
    if (keyBytes.length != signPublicKeyBytes) {
      throw const FolderMetadataRefusal('member.json has a key of the wrong size.');
    }
    return MemberFile(
      folderId: folderId,
      memberId: memberId,
      signPublicKey: keyBytes,
      deviceLabel: label,
    );
  }
}

/// A member id (a canonical UUID) from a device node id (32 lowercase hex).
String memberUuidFromNodeId(String nodeIdHex) =>
    '${nodeIdHex.substring(0, 8)}-${nodeIdHex.substring(8, 12)}-'
    '${nodeIdHex.substring(12, 16)}-${nodeIdHex.substring(16, 20)}-'
    '${nodeIdHex.substring(20)}';

/// The key fingerprint a person compares across devices: the protocol's 8-byte key
/// id as hex, in groups of four.
String keyFingerprint(Uint8List signPublicKey) {
  final hex = deriveKeyId(signPublicKey)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return [for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
}
