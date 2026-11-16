import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/vault/vault_folder.dart';
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
}
