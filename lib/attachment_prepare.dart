import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

/// Runs in a worker isolate — keep logic self-contained (no captured main-isolate state).
Future<void> _createFolderZipInIsolate(
  String directoryPath,
  String folderName,
  String zipOutPath,
) async {
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
    // Store (no deflate) keeps CPU low and matches typical LAN “bundle folder” use.
    await ZipFileEncoder().zipDirectory(
      dir,
      filename: zipOutPath,
      level: ZipFileEncoder.store,
      filter: (entity, _) {
        if (entity is File || entity is Directory) {
          return ZipFileOperation.include;
        }
        return ZipFileOperation.skip;
      },
    );
    if (!await zipFile.exists()) {
      throw AttachmentPrepareException('Archive was not created');
    }
  } catch (e) {
    try {
      if (await zipFile.exists()) await zipFile.delete();
    } catch (_) {}
    if (e is AttachmentPrepareException) rethrow;
    if (e is AttachmentPrepareCancelled) rethrow;
    throw AttachmentPrepareException(e.toString());
  }
}

/// Zips a folder with pure Dart ([archive]) on a **background isolate** so the UI thread
/// stays responsive. Uses ZIP store mode (no compression) for speed on large trees.
///
/// [isCancelled] is checked **after** the worker finishes; mid-zip cancel is not supported.
Future<void> createFolderZip({
  required String directoryPath,
  required String folderName,
  required String zipOutPath,
  required bool Function() isCancelled,
  void Function(Process process)? onProcessStarted,
}) async {
  // onProcessStarted is unused for Dart zip (kept for API compatibility with callers).
  final dp = directoryPath;
  final fn = folderName;
  final zp = zipOutPath;
  await Isolate.run(() => _createFolderZipInIsolate(dp, fn, zp));
  if (isCancelled()) throw const AttachmentPrepareCancelled();
}

String uniqueTempPath(String tempDir, String fileId, String displayName) {
  final safe = displayName.replaceAll(RegExp(r'[/\\]'), '_');
  return p.join(tempDir, '${fileId}_$safe');
}
