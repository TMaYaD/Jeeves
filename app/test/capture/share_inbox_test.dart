import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/capture/share_inbox.dart';

PendingShare _share({String? text, String? subject, bool image = false}) =>
    PendingShare(
      shareId: 's',
      receivedAtUtc: DateTime.utc(2026, 11, 11),
      text: text,
      subject: subject,
      attachmentRelativePath: image ? 'capture_attachments/s.png' : null,
      attachmentMimeType: image ? 'image/png' : null,
    );

void main() {
  group('captureFieldsForShare', () {
    test('text only: the text is the title', () {
      final fields = captureFieldsForShare(_share(text: '  Buy milk  '))!;
      expect(fields.title, 'Buy milk');
      expect(fields.notes, isNull);
    });

    test('text over 500 characters: clipped title, full text in notes', () {
      final long = 'a' * 700;
      final fields = captureFieldsForShare(_share(text: long))!;
      expect(fields.title, hasLength(captureTitleMaxLength));
      expect(fields.notes, long);
    });

    test('URL plus subject: subject is the title, full text in notes', () {
      final fields = captureFieldsForShare(
        _share(text: 'https://example.com/a', subject: 'Page title'),
      )!;
      expect(fields.title, 'Page title');
      expect(fields.notes, 'https://example.com/a');
    });

    test('URL with surrounding text: the text minus the URL is the title', () {
      final fields = captureFieldsForShare(
        _share(text: 'Read this https://example.com/a tonight'),
      )!;
      expect(fields.title, 'Read this tonight');
      expect(fields.notes, 'Read this https://example.com/a tonight');
    });

    test('URL alone: the URL is the title', () {
      final fields =
          captureFieldsForShare(_share(text: 'https://example.com/a'))!;
      expect(fields.title, 'https://example.com/a');
    });

    test('image only: fixed fallback title', () {
      expect(captureFieldsForShare(_share(image: true))!.title,
          sharedImageFallbackTitle);
    });

    test('image with subject and no text: the subject', () {
      expect(captureFieldsForShare(_share(image: true, subject: 'Receipt'))!.title,
          'Receipt');
    });

    test('image with text: the text is the title', () {
      expect(captureFieldsForShare(_share(image: true, text: 'Whiteboard'))!.title,
          'Whiteboard');
    });

    test('whitespace-only text counts as no text', () {
      expect(captureFieldsForShare(_share(text: '   ', image: true))!.title,
          sharedImageFallbackTitle);
    });

    test('nothing to capture yields null', () {
      expect(captureFieldsForShare(_share(text: '  ')), isNull);
    });
  });

  group('PendingShare.fromJson', () {
    test('rejects an unknown version', () {
      expect(
        () => PendingShare.fromJson({'version': 2, 'shareId': 'x', 'receivedAt': '2026-11-11T00:00:00Z'}),
        throwsFormatException,
      );
    });
  });
}
