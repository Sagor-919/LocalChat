import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/peer_device.dart';

typedef NotificationTapHandler = void Function(PeerDevice peer);

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  NotificationTapHandler? onTapPeer;

  Future<void> initialize() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const windowsSettings = WindowsInitializationSettings(
      appName: 'Local Chat',
      appUserModelId: 'com.example.local_chat',
      guid: 'f03d5c9a-09c3-4ac2-b8c3-1acb90bdc8a1',
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      windows: windowsSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map) return;
          final map = decoded.cast<String, dynamic>();
          final peer = PeerDevice(
            userId: map['id'] as String,
            displayName: map['name'] as String,
            ipAddress: map['ip'] as String,
            wsPort: (map['port'] as num).toInt(),
            lastSeen: DateTime.now(),
          );
          onTapPeer?.call(peer);
        } catch (_) {
          // ignore invalid payloads
        }
      },
    );

    await _requestPermissionsIfNeeded();
  }

  Future<void> _requestPermissionsIfNeeded() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;

    // On Android 13+ this triggers the runtime permission dialog.
    await android.requestNotificationsPermission();
  }

  Future<void> showIncomingMessage({
    required PeerDevice peer,
    required String message,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'drivechat_messages',
      'Messages',
      channelDescription: 'Incoming chat messages',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
    );

    final payload = jsonEncode({
      'id': peer.userId,
      'name': peer.displayName,
      'ip': peer.ipAddress,
      'port': peer.wsPort,
    });

    await _plugin.show(
      peer.userId.hashCode,
      peer.displayName,
      message,
      const NotificationDetails(android: androidDetails),
      payload: payload,
    );

    if (kDebugMode) {
      // ignore: avoid_print
      print('Notification shown for ${peer.displayName}');
    }
  }
}

