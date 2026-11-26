import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/vault/android_vault_folder.dart';

/// The vault's Android folder, over a mocked `jeeves/folder` channel.
///
/// The channel's other half is Kotlin, and no CI job runs it (there is no
/// on-device tier), so what is pinned here is the Dart half of the contract:
/// which operations the vault asks the channel for, and what it makes of the
/// answers. The Kotlin half is checked by the Gradle build and by hand.
void main() {
  // The channel is a platform channel, so the test needs the binding that
  // owns the binary messenger it is mocked on.
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const MethodChannel channel = MethodChannel('jeeves/folder');
  const String tree = 'content://com.android.externalstorage.documents/tree/docs';

  final List<MethodCall> calls = <MethodCall>[];
  Uint8List? pageBytes;
  List<String> files = <String>[];

  setUp(() {
    calls.clear();
    pageBytes = null;
    files = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'readAll':
          return pageBytes;
        case 'listFiles':
          return files;
        case 'listDirectories':
          return <String>[];
        default:
          return null;
      }
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('the vault reads a page whole', () {
    test('the text is decoded, multi-byte characters included', () async {
      pageBytes = utf8.encode('héllo\n');
      final folder = AndroidVaultFolder(tree);

      expect(await folder.read('Outcomes/a.md'), 'héllo\n');
    });

    test('the page is asked for as one document, not as a length and a read',
        () async {
      pageBytes = utf8.encode('hello\n');
      final folder = AndroidVaultFolder(tree);

      await folder.read('Outcomes/a.md');

      expect(calls.map((call) => call.method), ['readAll']);
      expect(calls.single.arguments?['tree'], tree);
      expect(calls.single.arguments?['path'], 'Outcomes/a.md');
    });

    test('the size of a page is never asked for', () async {
      // A provider may answer a question about a document's size with
      // nothing. A page of an unknown size is a page, and it is read whole:
      // only the absence of the document answers null.
      pageBytes = utf8.encode('hello\n');
      final folder = AndroidVaultFolder(tree);

      expect(await folder.read('Outcomes/a.md'), 'hello\n');
      expect(calls.map((call) => call.method), isNot(contains('length')));
    });

    test('a page that is not there is null', () async {
      final folder = AndroidVaultFolder(tree);

      expect(await folder.read('Outcomes/a.md'), isNull);
    });

    test('an empty page is an empty text, not a missing page', () async {
      pageBytes = Uint8List(0);
      final folder = AndroidVaultFolder(tree);

      expect(await folder.read('Outcomes/a.md'), '');
    });
  });

  group('the vault lists the pages of a folder', () {
    test('a temporary or backup document beside a page is not a page',
        () async {
      // The Kotlin writes its temporary and backup documents under these
      // names, and neither ends in `.md`: a leftover of either is never
      // listed as a page of its own.
      files = <String>[
        'a.md',
        'a.md.jeeves-tmp',
        'a.md.jeeves-bak',
      ];
      final folder = AndroidVaultFolder(tree);

      expect(await folder.listMarkdownFiles('Outcomes'), <String>['Outcomes/a.md']);
    });

    test('a folder with nothing in it has no pages', () async {
      final folder = AndroidVaultFolder(tree);

      expect(await folder.listMarkdownFiles('Outcomes'), isEmpty);
    });
  });

  group('the vault writes and removes a page', () {
    test('a page is written whole, under its path', () async {
      final folder = AndroidVaultFolder(tree);

      await folder.writeAtomically('Outcomes/a.md', 'héllo');

      expect(calls.map((call) => call.method), ['writeAtomically']);
      expect(calls.single.arguments?['path'], 'Outcomes/a.md');
      expect(calls.single.arguments?['bytes'], utf8.encode('héllo'));
    });

    test('a page is removed under its path', () async {
      final folder = AndroidVaultFolder(tree);

      await folder.remove('Outcomes/a.md');

      expect(calls.map((call) => call.method), ['remove']);
      expect(calls.single.arguments?['path'], 'Outcomes/a.md');
    });
  });
}
