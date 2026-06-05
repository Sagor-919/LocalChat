import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'storage_usage.dart';

class PartialDownloadEntry {
  final String path;
  final int bytes;
  final DateTime modified;

  const PartialDownloadEntry({
    required this.path,
    required this.bytes,
    required this.modified,
  });
}

bool _isPartialName(String path) {
  final name = p.basename(path).toLowerCase();
  return name.endsWith('.part') || name.endsWith('.partial');
}

/// Lists likely incomplete downloads (QA item 28). Read-only: this only
/// enumerates `.part`/`.partial` files and never deletes — a paused transfer is
/// persisted exactly as a `.part` file and must survive being viewed.
Future<List<PartialDownloadEntry>> scanPartialDownloads(String downloadRoot) async {
  if (kIsWeb || downloadRoot.isEmpty) return const [];
  final dir = Directory(downloadRoot);
  if (!await dir.exists()) return const [];
  final out = <PartialDownloadEntry>[];
  final stream = dir.list(recursive: true, followLinks: false).handleError(
    (_) {},
  );
  try {
    await for (final entity in stream) {
      if (entity is! File) continue;
      if (!_isPartialName(entity.path)) continue;
      try {
        final stat = await entity.stat();
        out.add(PartialDownloadEntry(
          path: entity.path,
          bytes: stat.size,
          modified: stat.modified,
        ));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Explicit, user-initiated cleanup: deletes `.part`/`.partial` files older than
/// [maxAge] (default 7 days), skipping any whose path is in [keepPaths] (e.g.
/// an active/paused transfer). Returns the number of files removed.
Future<int> cleanupExpiredPartialDownloads(
  String downloadRoot, {
  Duration maxAge = const Duration(days: 7),
  Set<String> keepPaths = const {},
}) async {
  if (kIsWeb || downloadRoot.isEmpty) return 0;
  final dir = Directory(downloadRoot);
  if (!await dir.exists()) return 0;
  final cutoff = DateTime.now().subtract(maxAge);
  var removed = 0;
  final stream = dir.list(recursive: true, followLinks: false).handleError(
    (_) {},
  );
  try {
    await for (final entity in stream) {
      if (entity is! File) continue;
      if (!_isPartialName(entity.path)) continue;
      if (keepPaths.contains(entity.path)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
          removed++;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return removed;
}

String describePartialDownloads(List<PartialDownloadEntry> entries) {
  if (entries.isEmpty) return 'No partial downloads';
  final total = entries.fold<int>(0, (s, e) => s + e.bytes);
  return '${entries.length} partial file(s), ${formatStorageBytes(total)} total';
}
