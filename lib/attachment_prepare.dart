import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class AttachmentPrepareException implements Exception {
  final String message;
  AttachmentPrepareException(this.message);
  @override
  String toString() => message;
}

class AttachmentPrepareCancelled implements Exception {
  const AttachmentPrepareCancelled();
}

const int kDefaultCopyChunkBytes = 8 * 1024 * 1024;

/// Streams [source] to [dest] in chunks so the UI isolate can yield between reads.
Future<void> copyFileChunked(
  String source,
  String dest, {
  int chunkSize = kDefaultCopyChunkBytes,
  required void Function(int bytesCopied, int totalBytes) onProgress,
  required bool Function() isCancelled,
}) async {
  final srcFile = File(source);
  if (!await srcFile.exists()) {
    throw AttachmentPrepareException('File not found: $source');
  }
  final total = await srcFile.length();
  final out = File(dest);
  if (await out.exists()) {
    try {
      await out.delete();
    } catch (_) {}
  }
  final sink = out.openWrite();
  try {
    var copied = 0;
    final raf = await srcFile.open();
    try {
      while (copied < total) {
        if (isCancelled()) throw const AttachmentPrepareCancelled();
        final take = total - copied < chunkSize ? total - copied : chunkSize;
        final buf = await raf.read(take);
        if (buf.isEmpty) break;
        sink.add(buf);
        copied += buf.length;
        onProgress(copied, total);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await raf.close();
    }
  } finally {
    await sink.close();
  }
  if (isCancelled()) throw const AttachmentPrepareCancelled();
}

/// Zips a folder with pure Dart ([archive]) so folder send works on Android
/// and Windows without a `tar` binary.
Future<void> createFolderZip({
  required String directoryPath,
  required String folderName,
  required String zipOutPath,
  required bool Function() isCancelled,
  void Function(Process process)? onProcessStarted,
}) async {
  final dir = Directory(directoryPath);
  if (!await dir.exists()) {
    throw AttachmentPrepareException('Folder not found: $folderName');
  }
  final zipFile = File(zipOutPath);
  if (await zipFile.exists()) {
    try {
      await zipFile.delete();
    } catch (_) {}
  }
  try {
    await ZipFileEncoder().zipDirectory(
      dir,
      filename: zipOutPath,
      filter: (entity, _) {
        if (isCancelled()) return ZipFileOperation.cancel;
        if (entity is File || entity is Directory) {
          return ZipFileOperation.include;
        }
        return ZipFileOperation.skip;
      },
    );
    if (isCancelled()) throw const AttachmentPrepareCancelled();
    if (!await zipFile.exists()) {
      throw AttachmentPrepareException('Archive was not created');
    }
  } on AttachmentPrepareCancelled {
    rethrow;
  } catch (e) {
    try {
      if (await zipFile.exists()) await zipFile.delete();
    } catch (_) {}
    if (e is AttachmentPrepareException) rethrow;
    throw AttachmentPrepareException(e.toString());
  }
}

String uniqueTempPath(String tempDir, String fileId, String displayName) {
  final safe = displayName.replaceAll(RegExp(r'[/\\]'), '_');
  return p.join(tempDir, '${fileId}_$safe');
}
