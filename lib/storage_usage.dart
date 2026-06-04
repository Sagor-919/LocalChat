import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Folder sends above this size show a confirmation dialog before Send.
const int kFolderSendConfirmThresholdBytes = 500 * 1024 * 1024;

/// Extra headroom required on the temp volume beyond the ZIP size estimate.
const int kFolderZipHeadroomBytes = 64 * 1024 * 1024;

/// Message-prep temp files use `{uuid}_{name}` under system / app temp.
final RegExp _localChatTempPrepName =
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}_.+');

String formatStorageBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

bool isLocalChatTempPrepFileName(String name) {
  return _localChatTempPrepName.hasMatch(name);
}

/// Directories scanned for orphaned send-prep files (ZIPs, content-uri copies).
Future<List<String>> localChatTempScanRoots() async {
  if (kIsWeb) return const [];
  final roots = <String>{Directory.systemTemp.path};
  try {
    final appTemp = await getTemporaryDirectory();
    roots.add(appTemp.path);
  } catch (_) {}
  return roots.toList();
}

Future<int> directoryByteSize(String dirPath) async {
  final dir = Directory(dirPath);
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } catch (_) {}
    }
  }
  return total;
}

/// Sum of file sizes under [directoryPath] (folder ZIP estimate; store mode ≈ raw size).
Future<int> estimateDirectoryByteSize(String directoryPath) async {
  return directoryByteSize(directoryPath);
}

Future<int> fileByteSize(String filePath) async {
  final f = File(filePath);
  if (!await f.exists()) return 0;
  try {
    return await f.length();
  } catch (_) {
    return 0;
  }
}

Future<({int bytes, int count})> scanLocalChatTempPrepArtifacts() async {
  if (kIsWeb) return (bytes: 0, count: 0);
  var bytes = 0;
  var count = 0;
  for (final root in await localChatTempScanRoots()) {
    final dir = Directory(root);
    if (!await dir.exists()) continue;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!isLocalChatTempPrepFileName(name)) continue;
      try {
        bytes += await entity.length();
        count++;
      } catch (_) {}
    }
  }
  return (bytes: bytes, count: count);
}

/// Deletes orphaned prep files (failed/cancelled sends). Does not touch download folder.
Future<({int deleted, int freedBytes})> cleanLocalChatTempPrepArtifacts() async {
  if (kIsWeb) return (deleted: 0, freedBytes: 0);
  var deleted = 0;
  var freed = 0;
  for (final root in await localChatTempScanRoots()) {
    final dir = Directory(root);
    if (!await dir.exists()) continue;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!isLocalChatTempPrepFileName(name)) continue;
      try {
        final len = await entity.length();
        await entity.delete();
        deleted++;
        freed += len;
      } catch (_) {}
    }
  }
  return (deleted: deleted, freedBytes: freed);
}

Future<String?> outboundAttachmentsDirectory() async {
  if (kIsWeb) return null;
  try {
    final root = await getApplicationDocumentsDirectory();
    return p.join(root.path, 'outbound_attachments');
  } catch (_) {
    return null;
  }
}

class StorageBreakdown {
  final int tempPrepBytes;
  final int tempPrepCount;
  final int outboundBytes;
  final int downloadBytes;
  final int databaseBytes;
  final String tempDirectoryLabel;
  final String? outboundPath;
  final String downloadPath;
  final String databasePath;

  const StorageBreakdown({
    required this.tempPrepBytes,
    required this.tempPrepCount,
    required this.outboundBytes,
    required this.downloadBytes,
    required this.databaseBytes,
    required this.tempDirectoryLabel,
    required this.outboundPath,
    required this.downloadPath,
    required this.databasePath,
  });
}

Future<StorageBreakdown> loadStorageBreakdown({
  required String downloadPath,
  required String databasePath,
}) async {
  if (kIsWeb) {
    return StorageBreakdown(
      tempPrepBytes: 0,
      tempPrepCount: 0,
      outboundBytes: 0,
      downloadBytes: 0,
      databaseBytes: 0,
      tempDirectoryLabel: '—',
      outboundPath: null,
      downloadPath: downloadPath,
      databasePath: databasePath,
    );
  }

  final tempScan = await scanLocalChatTempPrepArtifacts();
  final outboundDir = await outboundAttachmentsDirectory();
  final outboundBytes = outboundDir != null
      ? await directoryByteSize(outboundDir)
      : 0;
  final downloadBytes = downloadPath.isNotEmpty
      ? await directoryByteSize(downloadPath)
      : 0;
  final databaseBytes = await fileByteSize(databasePath);

  String tempLabel = Directory.systemTemp.path;
  try {
    final appTemp = await getTemporaryDirectory();
    if (appTemp.path != tempLabel) {
      tempLabel = '$tempLabel\n${appTemp.path}';
    }
  } catch (_) {}

  return StorageBreakdown(
    tempPrepBytes: tempScan.bytes,
    tempPrepCount: tempScan.count,
    outboundBytes: outboundBytes,
    downloadBytes: downloadBytes,
    databaseBytes: databaseBytes,
    tempDirectoryLabel: tempLabel,
    outboundPath: outboundDir,
    downloadPath: downloadPath,
    databasePath: databasePath,
  );
}

/// Best-effort free space on the volume containing [path]. Desktop folder-send checks.
Future<int?> freeBytesForPath(String path) async {
  if (kIsWeb || path.isEmpty) return null;
  try {
    if (Platform.isWindows) {
      return _freeBytesWindows(path);
    }
    if (Platform.isLinux || Platform.isMacOS) {
      return _freeBytesUnixDf(path);
    }
  } catch (_) {}
  return null;
}

Future<int?> _freeBytesWindows(String path) async {
  final normalized = p.normalize(path);
  String? drive;
  if (normalized.length >= 2 && normalized[1] == ':') {
    drive = normalized.substring(0, 2);
  }
  if (drive == null) return null;
  final result = await Process.run(
    'powershell',
    [
      '-NoProfile',
      '-Command',
      "(Get-PSDrive -Name '${drive[0]}').Free",
    ],
    runInShell: true,
  );
  if (result.exitCode != 0) return null;
  final text = (result.stdout as String).trim();
  final n = int.tryParse(text);
  return n;
}

Future<int?> _freeBytesUnixDf(String path) async {
  final result = await Process.run('df', ['-k', path]);
  if (result.exitCode != 0) return null;
  final lines = (result.stdout as String).split('\n');
  if (lines.length < 2) return null;
  final parts = lines.last.trim().split(RegExp(r'\s+'));
  if (parts.length < 4) return null;
  final availK = int.tryParse(parts[3]);
  if (availK == null) return null;
  return availK * 1024;
}

/// Checks download folder writable and optional [requiredBytes] free space.
Future<({bool ok, String? reason})> preflightReceiveDestination({
  required String downloadPath,
  required int requiredBytes,
}) async {
  if (kIsWeb || downloadPath.isEmpty) {
    return (ok: false, reason: 'Download folder is not configured');
  }
  final dir = Directory(downloadPath);
  try {
    if (!await dir.exists()) await dir.create(recursive: true);
  } catch (e) {
    return (ok: false, reason: 'Cannot access download folder');
  }
  final sep = Platform.pathSeparator;
  final probePath =
      '${dir.path}$sep.localchat_write_probe_${DateTime.now().microsecondsSinceEpoch}';
  final probe = File(probePath);
  try {
    await probe.writeAsString('ok', flush: true);
  } catch (_) {
    return (ok: false, reason: 'Cannot write to download folder');
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
  }
  if (requiredBytes > 0) {
    final free = await freeBytesForPath(downloadPath);
    if (free != null && free < requiredBytes + kFolderZipHeadroomBytes) {
      return (
        ok: false,
        reason: 'Not enough free space (need about '
            '${formatStorageBytes(requiredBytes)}, '
            'have about ${formatStorageBytes(free)})',
      );
    }
  }
  return (ok: true, reason: null);
}

/// Returns a user-facing warning when a folder send may not fit on the temp volume.
Future<String?> folderSendStorageWarning({
  required int estimatedFolderBytes,
  String? tempDirectoryPath,
}) async {
  if (kIsWeb) return null;
  final tempRoot = tempDirectoryPath ?? Directory.systemTemp.path;
  final needed = estimatedFolderBytes + kFolderZipHeadroomBytes;
  final free = await freeBytesForPath(tempRoot);
  if (free != null && free < needed) {
    return 'About ${formatStorageBytes(estimatedFolderBytes)} will be zipped in a '
        'temporary file. This device has about ${formatStorageBytes(free)} free on '
        'that drive; roughly ${formatStorageBytes(needed)} is recommended.';
  }
  if (estimatedFolderBytes >= kFolderSendConfirmThresholdBytes) {
    return 'About ${formatStorageBytes(estimatedFolderBytes)} will be copied into a '
        'temporary ZIP under your system temp folder before sending. The original '
        'folder on disk is not removed.';
  }
  return null;
}
