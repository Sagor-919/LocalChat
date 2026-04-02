import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;

import 'deferred_staged_file.dart';

/// True when [path] is an Android `content://` URI (desktop_drop passes these as strings).
bool isStagedDropContentUri(String path) {
  return path.trimLeft().toLowerCase().startsWith('content://');
}

/// Paths accepted into [DesktopDropQueue] (files, folders, Android content URIs).
bool stagedDropPathExists(String path) {
  if (path.isEmpty) return false;
  if (isStagedDropContentUri(path)) return true;
  return File(path).existsSync() || Directory(path).existsSync();
}

String _displayNameForContentUri(String uri) {
  try {
    final u = Uri.parse(uri);
    if (u.pathSegments.isNotEmpty) {
      final last = u.pathSegments.last;
      if (last.isNotEmpty) return last;
    }
  } catch (_) {}
  return 'shared_file';
}

/// Maps a queue/CLI filesystem path or Android `content://` string to a staged attachment.
DeferredStagedFile? deferredStagedFileFromLocalPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  if (isStagedDropContentUri(trimmed)) {
    return DeferredStagedFile(
      androidContentUri: trimmed,
      displayName: _displayNameForContentUri(trimmed),
    );
  }
  if (Directory(trimmed).existsSync()) {
    final folderName = p.basename(trimmed.replaceAll(RegExp(r'[/\\]+$'), ''));
    return DeferredStagedFile(
      sourcePath: trimmed,
      displayName: '$folderName.zip',
      kind: StagedSourceKind.folderToZip,
    );
  }
  return DeferredStagedFile(
    sourcePath: trimmed,
    displayName: p.basename(trimmed),
  );
}

/// Maps a desktop_drop [DropItem] to the same staging shape as the folder picker / share pipeline.
DeferredStagedFile? deferredStagedFileFromDropItem(DropItem item) {
  final path = item.path;
  final nameFromX = item.name;

  if (item is DropItemDirectory && path.isNotEmpty) {
    final normalized = path.replaceAll(RegExp(r'[/\\]+$'), '');
    final folderName = normalized.isNotEmpty
        ? p.basename(normalized)
        : (nameFromX.isNotEmpty ? nameFromX : 'folder');
    return DeferredStagedFile(
      sourcePath: path,
      displayName: '$folderName.zip',
      kind: StagedSourceKind.folderToZip,
    );
  }

  if (path.isNotEmpty && isStagedDropContentUri(path)) {
    final displayName = nameFromX.isNotEmpty
        ? nameFromX
        : _displayNameForContentUri(path);
    return DeferredStagedFile(
      androidContentUri: path,
      displayName: displayName,
    );
  }

  if (path.isNotEmpty && Directory(path).existsSync()) {
    final folderName = p.basename(path.replaceAll(RegExp(r'[/\\]+$'), ''));
    return DeferredStagedFile(
      sourcePath: path,
      displayName: '$folderName.zip',
      kind: StagedSourceKind.folderToZip,
    );
  }

  if (path.isEmpty) return null;

  final displayName =
      nameFromX.isNotEmpty ? nameFromX : p.basename(path);
  return DeferredStagedFile(
    sourcePath: path,
    displayName: displayName,
  );
}
