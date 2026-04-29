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

String _extFromPathLike(String raw) {
  final ext = p.extension(raw.trim());
  return ext;
}

String _contentUriExtension(String uri) {
  try {
    final u = Uri.parse(uri);
    if (u.pathSegments.isNotEmpty) {
      final last = u.pathSegments.last;
      final ext = _extFromPathLike(last);
      if (ext.isNotEmpty) return ext;
    }
  } catch (_) {}
  return '';
}

String _nameWithPreservedExtension({
  required String preferredName,
  required String fallbackPathLike,
}) {
  final name = preferredName.trim();
  if (name.isEmpty) return name;
  if (_extFromPathLike(name).isNotEmpty) return name;
  final ext = _extFromPathLike(fallbackPathLike);
  if (ext.isEmpty) return name;
  return '$name$ext';
}

/// Maps a queue/CLI filesystem path or Android `content://` string to a staged attachment.
DeferredStagedFile? deferredStagedFileFromLocalPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return null;
  if (isStagedDropContentUri(trimmed)) {
    final base = _displayNameForContentUri(trimmed);
    final displayName = _extFromPathLike(base).isNotEmpty
        ? base
        : '$base${_contentUriExtension(trimmed)}';
    return DeferredStagedFile(
      androidContentUri: trimmed,
      displayName: displayName,
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
    final fallbackName = _displayNameForContentUri(path);
    final baseName = nameFromX.isNotEmpty ? nameFromX : fallbackName;
    final withPathExt = _nameWithPreservedExtension(
      preferredName: baseName,
      fallbackPathLike: path,
    );
    final displayName = _extFromPathLike(withPathExt).isNotEmpty
        ? withPathExt
        : '$withPathExt${_contentUriExtension(path)}';
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
      nameFromX.isNotEmpty
          ? _nameWithPreservedExtension(
              preferredName: nameFromX,
              fallbackPathLike: path,
            )
          : p.basename(path);
  return DeferredStagedFile(
    sourcePath: path,
    displayName: displayName,
  );
}
