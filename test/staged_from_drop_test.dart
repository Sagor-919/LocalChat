import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/deferred_staged_file.dart';
import 'package:local_chat/staged_from_drop.dart';

void main() {
  test('isStagedDropContentUri', () {
    expect(isStagedDropContentUri('content://foo/bar'), isTrue);
    expect(isStagedDropContentUri('  content://x'), isTrue);
    expect(isStagedDropContentUri('/data/foo'), isFalse);
  });

  test('deferredStagedFileFromLocalPath content URI uses materialize path', () {
    final f = deferredStagedFileFromLocalPath('content://media/external/images/123');
    expect(f, isNotNull);
    expect(f!.androidContentUri, isNotNull);
    expect(f.sourcePath, isNull);
    expect(f.kind, StagedSourceKind.file);
  });

  test('deferredStagedFileFromLocalPath directory is folderToZip', () async {
    final dir = await Directory.systemTemp.createTemp('lc_drop_test_');
    try {
      final f = deferredStagedFileFromLocalPath(dir.path);
      expect(f, isNotNull);
      expect(f!.kind, StagedSourceKind.folderToZip);
      expect(f.displayName.endsWith('.zip'), isTrue);
      expect(f.sourcePath, dir.path);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('stagedDropPathExists accepts directories and content', () async {
    final dir = await Directory.systemTemp.createTemp('lc_drop_exist_');
    try {
      expect(stagedDropPathExists(dir.path), isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
    expect(stagedDropPathExists('content://a/b'), isTrue);
    expect(stagedDropPathExists('/nonexistent/path/xyz123'), isFalse);
  });
}
