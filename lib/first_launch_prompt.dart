import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_app_control.dart';
import 'android_storage_access.dart';
import 'app_settings.dart';

/// First open: notifications (mobile), storage (Android), then confirm or pick download folder.
Future<void> showFirstLaunchOnboardingIfNeeded(BuildContext context) async {
  if (kIsWeb) return;
  if (AppSettings.instance.firstLaunchOnboardingComplete) return;
  if (!context.mounted) return;

  final isAndroid = Platform.isAndroid;

  if (isAndroid) {
    final notifAllow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Welcome to Local Chat'),
        content: const Text(
          'Allow notifications to get alerts for new messages when the app is in the background.',
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
    if (!context.mounted) return;
    if (notifAllow == true) {
      final n = await Permission.notification.status;
      if (!n.isGranted) {
        await Permission.notification.request();
      }
    }

    if (!context.mounted) return;
    final batteryAllow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Battery optimization'),
        content: const Text(
          'To keep LAN chat and discovery connected in the background, please allow '
          'Local Chat to ignore battery optimization.\n\n'
          'On many phones (Samsung, Xiaomi, Huawei, OnePlus, etc.) the system otherwise '
          'suspends the app and you can lose connections even without force-closing the app.\n\n'
          'Messaging apps like WhatsApp ask for the same setting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (batteryAllow == true) {
      await androidRequestIgnoreBatteryOptimizations();
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Storage access'),
        content: const Text(
          'Local Chat needs storage access to save received files and to let you pick a download folder if you want.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    await Permission.storage.request();
  } else if (Platform.isIOS) {
    final n = await Permission.notification.status;
    if (!n.isGranted) {
      await Permission.notification.request();
    }
  }

  if (!context.mounted) return;

  var preview = AppSettings.instance.downloadPath.value;
  if (preview.isEmpty) {
    preview = await AppSettings.ensureLocalChatDownloadDirectory();
    await AppSettings.instance.setDownloadPath(preview);
  }

  if (!context.mounted) return;

  final useLocalChatDefault = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Download location'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'By default, files are saved under LocalChat Folder → Downloads. '
                'You can keep this or choose another folder (e.g. on your SD card).',
              ),
              const SizedBox(height: 12),
              Text(
                'Current location:',
                style: Theme.of(ctx).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SelectableText(
                preview,
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Choose folder'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Use LocalChat folder'),
          ),
        ],
      );
    },
  );

  if (!context.mounted) return;

  if (useLocalChatDefault == true) {
    final path = await AppSettings.ensureLocalChatDownloadDirectory();
    await AppSettings.instance.setDownloadPath(path);
  } else {
    if (isAndroid) {
      await ensureAndroidStorageForCustomDownloadFolder(context);
    }
    if (!context.mounted) return;
    final picked = await FilePicker.platform.getDirectoryPath();
    if (!context.mounted) return;
    if (picked != null) {
      if (await probeDirectoryWritable(picked)) {
        await AppSettings.instance.setDownloadPath(picked);
      } else {
        final fallback = await AppSettings.ensureLocalChatDownloadDirectory();
        await AppSettings.instance.setDownloadPath(fallback);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not write to that folder. Using LocalChat Folder → Downloads.',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  await AppSettings.instance.setFirstLaunchOnboardingComplete();
}
