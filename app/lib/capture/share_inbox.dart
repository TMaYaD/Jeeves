import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/gtd_database.dart';

/// Longest `captures.title` the schema accepts.
const int captureTitleMaxLength = 500;

/// Title used for an image shared with no text and no subject.
const String sharedImageFallbackTitle = 'Shared image';

/// A share the native `ShareReceiverActivity` queued as
/// `filesDir/share_inbox/<shareId>.json`. The format is pinned by the fixtures
/// in `test/fixtures/share_inbox/`; the Kotlin writer names them as its contract.
class PendingShare {
  const PendingShare({
    required this.shareId,
    required this.receivedAtUtc,
    this.text,
    this.subject,
    this.attachmentRelativePath,
    this.attachmentMimeType,
  });

  final String shareId;
  final DateTime receivedAtUtc;
  final String? text;
  final String? subject;
  final String? attachmentRelativePath;
  final String? attachmentMimeType;

  bool get hasAttachment => attachmentRelativePath != null;

  /// Throws [FormatException] for anything that is not a version-1 share.
  factory PendingShare.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('pending share is not a JSON object');
    }
    if (json['version'] != 1) {
      throw FormatException('unknown pending share version ${json['version']}');
    }
    final shareId = json['shareId'];
    final receivedAt = json['receivedAt'];
    if (shareId is! String || shareId.isEmpty || receivedAt is! String) {
      throw const FormatException('pending share lacks shareId or receivedAt');
    }
    final attachment = json['attachment'];
    String? path;
    String? mime;
    if (attachment != null) {
      if (attachment is! Map<String, Object?> ||
          attachment['relativePath'] is! String ||
          attachment['mimeType'] is! String) {
        throw const FormatException('pending share attachment is malformed');
      }
      path = attachment['relativePath'] as String;
      mime = attachment['mimeType'] as String;
    }
    final text = json['text'];
    final subject = json['subject'];
    if ((text != null && text is! String) ||
        (subject != null && subject is! String)) {
      throw const FormatException('pending share text/subject is not a string');
    }
    return PendingShare(
      shareId: shareId,
      receivedAtUtc: DateTime.parse(receivedAt).toUtc(),
      text: text as String?,
      subject: subject as String?,
      attachmentRelativePath: path,
      attachmentMimeType: mime,
    );
  }
}

final RegExp _httpUrl = RegExp(r'https?://\S+');

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

String _clipTitle(String title) => title.length <= captureTitleMaxLength
    ? title
    : title.substring(0, captureTitleMaxLength);

/// Maps a share onto the raw Capture's `(title, notes)`.
///
/// * URL in the text → full text in notes; title is the subject, else the text
///   with the URL removed, else the URL itself.
/// * No URL → title is the text (clipped to the schema limit, with the full text
///   in notes when clipped). With an image and no text: the subject, else
///   [sharedImageFallbackTitle].
///
/// Returns null when the share carries nothing to capture (no text, no subject,
/// no attachment).
({String title, String? notes})? captureFieldsForShare(PendingShare share) {
  final text = _nonBlank(share.text);
  final subject = _nonBlank(share.subject);

  if (text != null) {
    final url = _httpUrl.firstMatch(text)?.group(0);
    if (url != null && !share.hasAttachment) {
      final withoutUrl = _nonBlank(text.replaceAll(_httpUrl, ' ').replaceAll(RegExp(r'\s+'), ' '));
      return (title: _clipTitle(subject ?? withoutUrl ?? url), notes: text);
    }
    return (
      title: _clipTitle(text),
      notes: text.length > captureTitleMaxLength ? text : null,
    );
  }
  if (subject != null) return (title: _clipTitle(subject), notes: null);
  if (share.hasAttachment) return (title: sharedImageFallbackTitle, notes: null);
  return null;
}

/// Directory, under the app files directory, the native side queues shares in.
const String shareInboxDirectoryName = 'share_inbox';

/// Databases a drain is currently running against.
final Expando<bool> _draining = Expando<bool>('share inbox drain');

/// Turns every queued share into a raw Capture (plus attachment row) and
/// deletes its file once the database commit has happened.
///
/// Idempotent: a share whose Capture already exists (id = `shareId`) only has
/// its file deleted. A file that does not parse, or whose share carries nothing
/// to capture, is logged and left in place. Returns the number of Captures
/// created. A second call against the same database while one is running returns 0.
Future<int> drainShareInbox({
  required GtdDatabase db,
  required Directory filesDirectory,
  required String userId,
}) async {
  if (_draining[db] == true) return 0;
  _draining[db] = true;
  try {
    final inbox = Directory(p.join(filesDirectory.path, shareInboxDirectoryName));
    if (!await inbox.exists()) return 0;

    final queued = <(File, PendingShare)>[];
    await for (final entity in inbox.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final share = PendingShare.fromJson(jsonDecode(await entity.readAsString()));
        queued.add((entity, share));
      } on Object catch (error) {
        debugPrint('share inbox: leaving unreadable ${entity.path}: $error');
      }
    }
    queued.sort((a, b) => a.$2.receivedAtUtc.compareTo(b.$2.receivedAtUtc));

    var created = 0;
    for (final (file, share) in queued) {
      try {
        final existing = await (db.select(db.captures)
              ..where((c) => c.id.equals(share.shareId)))
            .getSingleOrNull();
        if (existing == null) {
          final fields = captureFieldsForShare(share);
          if (fields == null) {
            debugPrint('share inbox: leaving empty share ${file.path}');
            continue;
          }
          await db.captureDao.insertSharedCapture(
            CapturesCompanion(
              id: Value(share.shareId),
              title: Value(fields.title),
              notes: Value(fields.notes),
              captureSource: const Value('share_sheet'),
              userId: Value(userId),
              createdAt: Value(share.receivedAtUtc),
              updatedAt: Value(share.receivedAtUtc),
            ),
            attachment: share.hasAttachment
                ? CaptureAttachmentsCompanion(
                    captureId: Value(share.shareId),
                    relativePath: Value(share.attachmentRelativePath!),
                    mimeType: Value(share.attachmentMimeType!),
                    createdAt: Value(share.receivedAtUtc),
                    userId: Value(userId),
                  )
                : null,
          );
          created++;
        }
        await file.delete();
      } on Object catch (error) {
        debugPrint('share inbox: failed to drain ${file.path}: $error');
      }
    }
    return created;
  } finally {
    _draining[db] = false;
  }
}
