import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Opens this app’s page in system settings (e.g. after storage access was denied).
Future<bool> openLocalChatAppSettings() => openAppSettings();

/// Whether we can create files under [dirPath] with dart:io (needed for received files).
Future<bool> probeDirectoryWritable(String dirPath) async {
  if (dirPath.isEmpty) return false;
  try {
    final d = Directory(dirPath);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    final sep = Platform.pathSeparator;
    final test = File('${d.path}$sep.localchat_write_probe');
    await test.writeAsString('ok', flush: true);
    await test.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Requests storage access so a user-chosen download folder works on Android (scoped storage).
Future<void> ensureAndroidStorageForCustomDownloadFolder(BuildContext context) async {
  if (!Platform.isAndroid) return;

  var st = await Permission.storage.status;
  if (!st.isGranted) {
    st = await Permission.storage.request();
  }

  if (await Permission.manageExternalStorage.isGranted) return;

  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Allow file access'),
      content: const Text(
        'To save received files to a folder you pick, Android needs “All files access” '
        '(or the closest option on your device). Tap Continue, then allow it on the next screen.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  if (go == true) {
    await Permission.manageExternalStorage.request();
  }
}
