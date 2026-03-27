import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void registerLanForegroundPort() {
  if (kIsWeb || !Platform.isAndroid) return;
  FlutterForegroundTask.initCommunicationPort();
}

/// Must match [NotificationButton.id] in [startLanForegroundIfNeeded].
const _kLanForegroundCloseButtonId = 'localchat_close_bg';

@pragma('vm:entry-point')
void localChatForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_LocalChatFgHandler());
}

class _LocalChatFgHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _kLanForegroundCloseButtonId) {
      FlutterForegroundTask.stopService();
    }
  }
}

void initLanForegroundTask() {
  if (kIsWeb || !Platform.isAndroid) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'local_chat_background',
      channelName: 'Local Chat',
      channelDescription:
          'Keeps LAN discovery, chat, and file transfer active in background.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> startLanForegroundIfNeeded() async {
  if (kIsWeb || !Platform.isAndroid) return;
  if (await FlutterForegroundTask.isRunningService) return;
  final perm = await FlutterForegroundTask.checkNotificationPermission();
  if (perm != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  await FlutterForegroundTask.startService(
    notificationTitle: 'Local Chat',
    notificationText: 'Running in background — LAN active',
    notificationButtons: [
      const NotificationButton(
        id: _kLanForegroundCloseButtonId,
        text: 'Close',
      ),
    ],
    callback: localChatForegroundCallback,
  );
}

Future<void> stopLanForeground() async {
  if (kIsWeb || !Platform.isAndroid) return;
  if (!await FlutterForegroundTask.isRunningService) return;
  try {
    await FlutterForegroundTask.stopService();
  } catch (_) {}
}
