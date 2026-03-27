import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_settings.dart';

/// One-time welcome + notification permission on Android (API 33+).
Future<void> showFirstLaunchPermissionsIfNeeded(BuildContext context) async {
  if (kIsWeb || !Platform.isAndroid) return;
  if (AppSettings.instance.firstLaunchPermissionsDone) return;

  if (!context.mounted) return;

  final allow = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Welcome to Local Chat'),
        content: const Text(
          'Allow notifications so you can see new messages when the app is not on screen. '
          'You can change this anytime in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow notifications'),
          ),
        ],
      );
    },
  );

  if (!context.mounted) return;

  if (allow == true) {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      await Permission.notification.request();
    }
  }

  await AppSettings.instance.setFirstLaunchPermissionsDone();
}
