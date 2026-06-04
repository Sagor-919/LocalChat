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

/// Lists likely incomplete downloads (QA item 28).
Future<List<PartialDownloadEntry>> scanPartialDownloads(String downloadRoot) async {
  if (kIsWeb || downloadRoot.isEmpty) return const [];
  final dir = Directory(downloadRoot);
  if (!await dir.exists()) return const [];
  final cutoff = DateTime.now().subtract(const Duration(days: 7));
  final out = <PartialDownloadEntry>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path).toLowerCase();
    if (!name.endsWith('.part') &&
        !name.endsWith('.partial') &&
        !name.startsWith('.')) {
      continue;
    }
    try {
      final stat = await entity.stat();
      if (stat.modified.isBefore(cutoff)) {
        await entity.delete();
        continue;
      }
      out.add(PartialDownloadEntry(
        path: entity.path,
        bytes: stat.size,
        modified: stat.modified,
      ));
    } catch (_) {}
  }
  return out;
}

String describePartialDownloads(List<PartialDownloadEntry> entries) {
  if (entries.isEmpty) return 'No partial downloads';
  final total = entries.fold<int>(0, (s, e) => s + e.bytes);
  return '${entries.length} partial file(s), ${formatStorageBytes(total)} total';
}
