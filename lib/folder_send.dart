import 'dart:io';

import 'package:path/path.dart' as p;

class FolderEntry {
  final String relativePath;
  final String absolutePath;
  final int sizeBytes;

  const FolderEntry({
    required this.relativePath,
    required this.absolutePath,
    required this.sizeBytes,
  });
}

/// Rejects `..`, absolute paths, and empty segments.
String? sanitizeFolderRelativePath(String raw) {
  final normalized = raw.replaceAll('\\', '/');
  if (normalized.isEmpty) return null;
  if (normalized.startsWith('/')) return null;
  final parts = normalized.split('/');
  for (final part in parts) {
    if (part.isEmpty || part == '.' || part == '..') return null;
  }
  return parts.join('/');
}

/// Lists all files under [rootDirectory] with POSIX-style relative paths.
Future<List<FolderEntry>> listFolderEntries(String rootDirectory) async {
  final root = Directory(rootDirectory);
  if (!await root.exists()) {
    throw StateError('Folder not found');
  }
  final rootPath = p.normalize(root.absolute.path);
  final out = <FolderEntry>[];

  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final abs = p.normalize(entity.absolute.path);
    if (!p.isWithin(rootPath, abs) && abs != rootPath) continue;
    var rel = p.relative(abs, from: rootPath);
    rel = rel.replaceAll('\\', '/');
    final safe = sanitizeFolderRelativePath(rel);
    if (safe == null) continue;
    int size = 0;
    try {
      size = await entity.length();
    } catch (_) {}
    out.add(FolderEntry(
      relativePath: safe,
      absolutePath: abs,
      sizeBytes: size,
    ));
  }

  out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return out;
}

int totalFolderBytes(Iterable<FolderEntry> entries) {
  var n = 0;
  for (final e in entries) {
    n += e.sizeBytes;
  }
  return n;
}
