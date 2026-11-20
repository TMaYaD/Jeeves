import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/vault/vault_folder_io.dart';

void main() {
  late Directory root;
  late DirectoryVaultFolder folder;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('vault_folder_test');
    folder = DirectoryVaultFolder(root);
  });
  tearDown(() => root.delete(recursive: true));

  test('write creates parents, read returns text, missing file is null',
      () async {
    expect(await folder.read('Outcomes/a.md'), isNull);
    await folder.writeAtomically('Outcomes/a.md', 'hello\n');
    expect(await folder.read('Outcomes/a.md'), 'hello\n');
  });

  test('write leaves no temporary file and overwrites', () async {
    await folder.writeAtomically('Inbox/x.md', 'one');
    await folder.writeAtomically('Inbox/x.md', 'two');
    expect(await folder.read('Inbox/x.md'), 'two');
    expect(await folder.listMarkdownFiles('Inbox'), ['Inbox/x.md']);
    expect(root.listSync(recursive: true).whereType<File>().length, 1);
  });

  test('list returns only sorted markdown files, empty for missing folder',
      () async {
    expect(await folder.listMarkdownFiles('Sessions'), isEmpty);
    await folder.writeAtomically('Outcomes/b.md', 'b');
    await folder.writeAtomically('Outcomes/a.md', 'a');
    File('${root.path}/Outcomes/note.txt').writeAsStringSync('t');
    expect(await folder.listMarkdownFiles('Outcomes'),
        ['Outcomes/a.md', 'Outcomes/b.md']);
  });

  test('remove deletes the file and tolerates a missing one', () async {
    await folder.writeAtomically('Outcomes/a.md', 'a');
    await folder.remove('Outcomes/a.md');
    await folder.remove('Outcomes/a.md');
    expect(await folder.read('Outcomes/a.md'), isNull);
  });

  test('two writers of one page do not share a temporary file', () async {
    // Two plugin instances write the same page at once — the old vault's
    // writer and the new one's. Each write needs a temporary file of its own,
    // or the first rename consumes the second one's file.
    final other = DirectoryVaultFolder(root);
    await Future.wait([
      folder.writeAtomically('Outcomes/a.md', 'one'),
      other.writeAtomically('Outcomes/a.md', 'two'),
    ]);
    expect(await folder.read('Outcomes/a.md'), anyOf('one', 'two'));
    expect(root.listSync(recursive: true).whereType<File>().length, 1);
  });

  test('a temporary file left behind is not a page', () async {
    await folder.writeAtomically('Outcomes/a.md', 'a');
    File('${root.path}/Outcomes/a.md.jeeves-tmp').writeAsStringSync('old');
    expect(await folder.listMarkdownFiles('Outcomes'), ['Outcomes/a.md']);
    await folder.writeAtomically('Outcomes/a.md', 'b');
    expect(await folder.read('Outcomes/a.md'), 'b');
  });

  test('a folder that is a link out of the vault is refused', () async {
    // A file syncer, or anything else with access to the folder, can leave a
    // link behind. Dart's file operations follow one, so a link out of the
    // vault would take the read or the write outside it.
    final outside = await Directory.systemTemp.createTemp('vault_outside');
    addTearDown(() => outside.delete(recursive: true));
    Link('${root.path}/Outcomes').createSync(outside.path);

    await expectLater(
        folder.read('Outcomes/a.md'), throwsArgumentError);
    await expectLater(
        folder.writeAtomically('Outcomes/a.md', 'a'), throwsArgumentError);
    expect(outside.listSync().whereType<File>(), isEmpty);
  });

  test('a file that is a link out of the vault is refused', () async {
    final outside = await Directory.systemTemp.createTemp('vault_outside');
    addTearDown(() => outside.delete(recursive: true));
    final secret = File('${outside.path}/secret.txt')
      ..writeAsStringSync('not a page');
    Directory('${root.path}/Outcomes').createSync();
    Link('${root.path}/Outcomes/a.md').createSync(secret.path);

    await expectLater(folder.read('Outcomes/a.md'), throwsArgumentError);
  });
}
