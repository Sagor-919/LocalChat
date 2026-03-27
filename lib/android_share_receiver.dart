import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pending_share_attachments.dart';

/// Android: SEND / SEND_MULTIPLE → native copies streams to cache → Dart pulls paths.
class AndroidShareReceiver {
  static const _ch = MethodChannel('local_chat/share');

  /// Set from [LocalChatApp] to show a snackbar when new shares arrive (any route).
  static void Function(int count)? onSharesPulled;

  /// Call from [main] after binding init so warm-start shares can notify Dart.
  static void installPushHandler() {
    if (kIsWeb || !Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shareIntentUpdated') {
        await pullPendingFromPlatform();
      }
    });
  }

  static Future<void> pullPendingFromPlatform() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('takePendingShares');
      final paths = raw?.cast<String>() ?? <String>[];
      if (paths.isEmpty) return;
      PendingShareAttachments.instance.addAll(paths);
      onSharesPulled?.call(paths.length);
    } catch (_) {}
  }
}
