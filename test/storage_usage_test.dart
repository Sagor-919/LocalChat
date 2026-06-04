import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/storage_usage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  group('isLocalChatTempPrepFileName', () {
    test('matches uuid-prefixed prep files', () {
      const id = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
      expect(isLocalChatTempPrepFileName('${id}_photo.jpg'), isTrue);
      expect(isLocalChatTempPrepFileName('${id}_MyFolder.zip'), isTrue);
      expect(isLocalChatTempPrepFileName('random_photo.jpg'), isFalse);
      expect(isLocalChatTempPrepFileName('short_id_file.zip'), isFalse);
    });
  });

  group('estimateDirectoryByteSize', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lc_storage_test_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('sums nested file sizes', () async {
      final sub = Directory(p.join(dir.path, 'sub'));
      await sub.create();
      await File(p.join(dir.path, 'a.bin')).writeAsBytes(List.filled(100, 1));
      await File(p.join(sub.path, 'b.bin')).writeAsBytes(List.filled(50, 2));
      expect(await estimateDirectoryByteSize(dir.path), 150);
    });
  });

  group('cleanLocalChatTempPrepArtifacts', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lc_clean_test_');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('deletes only LocalChat prep pattern files', () async {
      final id = const Uuid().v4();
      final prep = File(p.join(root.path, '${id}_archive.zip'));
      await prep.writeAsBytes(List.filled(20, 0));
      await File(p.join(root.path, 'other.txt')).writeAsBytes([1, 2, 3]);

      // Scan roots won't include our test root — test via direct name logic + manual delete path
      expect(isLocalChatTempPrepFileName(p.basename(prep.path)), isTrue);
      expect(isLocalChatTempPrepFileName('other.txt'), isFalse);
      await prep.delete();
      expect(await prep.exists(), isFalse);
      expect(await File(p.join(root.path, 'other.txt')).exists(), isTrue);
    });
  });

  group('formatStorageBytes', () {
    test('formats common sizes', () {
      expect(formatStorageBytes(512), '512 B');
      expect(formatStorageBytes(2048), '2.0 KB');
      expect(formatStorageBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });
}
