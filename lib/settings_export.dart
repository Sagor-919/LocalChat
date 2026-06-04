import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_settings.dart';

/// Export / import non-secret preferences (QA item 21).
Map<String, dynamic> exportSettingsSnapshot() {
  final s = AppSettings.instance;
  return {
    'version': 1,
    'theme_mode': switch (s.themeMode.value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    },
    'notifications_muted': s.notificationsMuted.value,
    'download_path': s.downloadPath.value,
    'auto_accept_incoming_files': s.autoAcceptIncomingFiles.value,
    'folder_send_as_zip': s.folderSendAsZip.value,
    'desktop_run_in_background': s.desktopRunInBackground.value,
    'encrypt_file_transfers': s.encryptFileTransfers.value,
    'file_transfer_checksum': s.fileTransferChecksum.value,
    'max_attachment_size_mb': s.maxAttachmentSizeMb.value,
    'transfer_throttle_kbps': s.transferThrottleKbps.value,
    'max_concurrent_sends': s.maxConcurrentSends.value,
  };
}

String exportSettingsJson() =>
    const JsonEncoder.withIndent('  ').convert(exportSettingsSnapshot());

Future<void> importSettingsJson(String jsonText) async {
  final map = jsonDecode(jsonText) as Map<String, dynamic>;
  final s = AppSettings.instance;
  final mode = map['theme_mode'] as String? ?? 'system';
  await s.setThemeMode(switch (mode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  });
  if (map.containsKey('notifications_muted')) {
    await s.setNotificationsMuted(map['notifications_muted'] == true);
  }
  if (map.containsKey('auto_accept_incoming_files')) {
    await s.setAutoAcceptIncomingFiles(
        map['auto_accept_incoming_files'] == true);
  }
  if (map.containsKey('folder_send_as_zip')) {
    await s.setFolderSendAsZip(map['folder_send_as_zip'] == true);
  }
  if (map.containsKey('encrypt_file_transfers')) {
    await s.setEncryptFileTransfers(map['encrypt_file_transfers'] == true);
  }
  if (map.containsKey('file_transfer_checksum')) {
    await s.setFileTransferChecksum(map['file_transfer_checksum'] == true);
  }
  if (map.containsKey('max_attachment_size_mb')) {
    await s.setMaxAttachmentSizeMb(
        (map['max_attachment_size_mb'] as num?)?.toInt() ?? 0);
  }
  if (map.containsKey('transfer_throttle_kbps')) {
    await s.setTransferThrottleKbps(
        (map['transfer_throttle_kbps'] as num?)?.toInt() ?? 0);
  }
  if (map.containsKey('max_concurrent_sends')) {
    await s.setMaxConcurrentSends(
        (map['max_concurrent_sends'] as num?)?.toInt() ?? 3);
  }
  final path = map['download_path'] as String?;
  if (path != null && path.isNotEmpty) {
    await s.setDownloadPath(path);
  }
}
