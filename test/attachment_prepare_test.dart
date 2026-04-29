import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/attachment_prepare.dart';
import 'package:path/path.dart' as path_lib;

void main() {
  group('uniqueTempPath', () {
    test('sanitizes path segments in display name', () {
      final full = uniqueTempPath(r'.', 'fid', r'evil/name\foo.txt');
      final base = path_lib.basename(full);
      expect(base.startsWith('fid_'), isTrue);
      expect(base.contains('evil'), isTrue);
      expect(base.contains('foo.txt'), isTrue);
      expect(base.contains('/'), isFalse);
      expect(base.contains(r'\'), isFalse);
    });
  });

  group('copyFileChunked', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lc_attach_test_');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('copies entire file and reports monotonic progress', () async {
      final src = File('${dir.path}${Platform.pathSeparator}src.bin');
      await src.writeAsBytes(List<int>.generate(5000, (i) => i % 256));
      final dst = File('${dir.path}${Platform.pathSeparator}dst.bin');
      final progress = <int>[];
      await copyFileChunked(
        src.path,
        dst.path,
        chunkSize: 1000,
        onProgress: (copied, total) {
          progress.add(copied);
          expect(total, 5000);
          if (progress.length > 1) {
            expect(copied, greaterThanOrEqualTo(progress[progress.length - 2]));
          }
        },
        isCancelled: () => false,
      );
      expect(await dst.readAsBytes(), await src.readAsBytes());
      expect(progress, isNotEmpty);
      expect(progress.last, 5000);
    });

    test('throws AttachmentPrepareException if source missing', () async {
      final dst = File('${dir.path}${Platform.pathSeparator}out.bin');
      await expectLater(
        copyFileChunked(
          '${dir.path}${Platform.pathSeparator}missing.bin',
          dst.path,
          chunkSize: 64,
          onProgress: (copied, total) {
            expect(copied, greaterThanOrEqualTo(0));
            expect(total, greaterThanOrEqualTo(0));
          },
          isCancelled: () => false,
        ),
        throwsA(isA<AttachmentPrepareException>()),
      );
    });

    test('throws AttachmentPrepareCancelled when cancelled mid-copy', () async {
      final src = File('${dir.path}${Platform.pathSeparator}src.bin');
      await src.writeAsBytes(List<int>.generate(10000, (i) => i % 251));
      final dst = File('${dir.path}${Platform.pathSeparator}dst.bin');
      var cancel = false;
      await expectLater(
        copyFileChunked(
          src.path,
          dst.path,
          chunkSize: 100,
          onProgress: (copied, _) {
            if (copied >= 250) cancel = true;
          },
          isCancelled: () => cancel,
        ),
        throwsA(isA<AttachmentPrepareCancelled>()),
      );
    });
  });

  group('createFolderZip', () {
    late Directory work;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('lc_zip_test_');
    });

    tearDown(() async {
      if (await work.exists()) {
        await work.delete(recursive: true);
      }
    });

    test('writes a zip from folder (pure Dart archive)', () async {
      final folder = Directory('${work.path}${Platform.pathSeparator}pack');
      await folder.create();
      await File('${folder.path}${Platform.pathSeparator}a.txt')
          .writeAsString('hello');
      final zipPath = '${work.path}${Platform.pathSeparator}out.zip';
      var cancelled = false;
      await createFolderZip(
        directoryPath: folder.path,
        folderName: 'pack',
        zipOutPath: zipPath,
        isCancelled: () => cancelled,
      );
      final z = File(zipPath);
      expect(await z.exists(), isTrue);
      expect(await z.length(), greaterThan(0));
    });
  });
}
