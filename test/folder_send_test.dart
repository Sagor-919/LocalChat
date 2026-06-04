import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/folder_send.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sanitizeFolderRelativePath', () {
    test('rejects parent segments', () {
      expect(sanitizeFolderRelativePath('../secret.txt'), isNull);
      expect(sanitizeFolderRelativePath('ok/file.txt'), 'ok/file.txt');
    });
  });

  group('listFolderEntries', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lc_folder_send_');
      final sub = Directory(p.join(dir.path, 'sub'));
      await sub.create();
      await File(p.join(dir.path, 'a.txt')).writeAsString('aa');
      await File(p.join(sub.path, 'b.txt')).writeAsString('bbb');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('lists all files with relative paths', () async {
      final entries = await listFolderEntries(dir.path);
      expect(entries.length, 2);
      expect(
        entries.map((e) => e.relativePath).toSet(),
        {'a.txt', 'sub/b.txt'},
      );
      expect(totalFolderBytes(entries), greaterThan(4));
    });
  });
}
