import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/capture/share_inbox.dart';
import 'package:jeeves/capture/share_inbox_host.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/screens/inbox/inbox_screen.dart';
import 'package:path/path.dart' as p;
import '../test_helpers.dart';

const _fixtures = 'test/fixtures/share_inbox';
const _imageShareId = '44444444-4444-4444-8444-444444444444';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late Directory filesDirectory;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    filesDirectory = await Directory.systemTemp.createTemp('share_journey');
    final inbox = Directory(p.join(filesDirectory.path, 'share_inbox'))
      ..createSync();
    for (final name in ['text', 'url_with_subject', 'url_only', 'image']) {
      File('$_fixtures/$name.json')
          .copySync(p.join(inbox.path, '$name.json'));
    }
    final attachments =
        Directory(p.join(filesDirectory.path, 'capture_attachments'))
          ..createSync();
    File(p.join(attachments.path, '$_imageShareId.png'))
        .writeAsBytesSync(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
  });

  tearDown(() async {
    await db.close();
    await filesDirectory.delete(recursive: true);
  });

  testWidgets('shared text, URLs and an image land in the Inbox on app open',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          hasAnyItemProvider.overrideWith((ref) => Stream.value(true)),
        ],
        child: MaterialApp(
          home: ShareInboxHost(
            filesDirectoryLoader: () async => filesDirectory,
            child: const InboxScreen(),
          ),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Call the plumber about the boiler'), findsOneWidget);
    expect(find.text('An interesting article'), findsOneWidget);
    expect(find.text('https://example.com/bare'), findsOneWidget);
    expect(find.text('Shared image'), findsOneWidget);

    final captures = await db.select(db.captures).get();
    expect(captures, hasLength(4));
    for (final capture in captures) {
      expect(capture.captureSource, 'share_sheet');
      expect(capture.clarifiedAt, isNull);
    }
    final urlCapture =
        captures.singleWhere((c) => c.title == 'An interesting article');
    expect(urlCapture.notes, 'https://example.com/article');

    final attachment = await db.select(db.captureAttachments).getSingle();
    expect(attachment.captureId, _imageShareId);
    expect(File(p.join(filesDirectory.path, attachment.relativePath)).existsSync(),
        isTrue);

    final queue = Directory(p.join(filesDirectory.path, 'share_inbox'));
    expect(queue.listSync(), isEmpty);
  });

  test('draining twice, or after a crash before the delete, adds nothing',
      () async {
    final first = await drainShareInbox(
        db: db, filesDirectory: filesDirectory, userId: 'local');
    expect(first, 4);

    // Simulate a crash between the commit and the file delete.
    File('$_fixtures/text.json').copySync(
        p.join(filesDirectory.path, 'share_inbox', 'text.json'));
    final second = await drainShareInbox(
        db: db, filesDirectory: filesDirectory, userId: 'local');
    expect(second, 0);
    expect(await db.select(db.captures).get(), hasLength(4));
    expect(Directory(p.join(filesDirectory.path, 'share_inbox')).listSync(),
        isEmpty);
  });

  test('a malformed pending share survives the drain untouched', () async {
    final bad = File(p.join(filesDirectory.path, 'share_inbox', 'bad.json'))
      ..writeAsStringSync('{not json');
    await drainShareInbox(
        db: db, filesDirectory: filesDirectory, userId: 'local');
    expect(bad.existsSync(), isTrue);
    expect(bad.readAsStringSync(), '{not json');
    expect(await db.select(db.captures).get(), hasLength(4));
  });
}
