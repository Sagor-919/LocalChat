import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'home_screen.dart';
import 'message_model.dart';
import 'message_store.dart';

late DeviceInfo _me;
late DiscoveryService _discovery;
late ConnectionService _connections;
late MessageStore _store;
final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();
bool _appInForeground = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _me = await DeviceInfo.load();
  _store = await MessageStore.init();
  _discovery = DiscoveryService(me: _me);
  _connections = ConnectionService(me: _me);
  await _connections.startServer();
  await _discovery.start();

  await _notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      windows: WindowsInitializationSettings(
          appName: 'Local Chat',
          appUserModelId: 'com.localchat.app',
          guid: 'd3c1f8a0-1234-5678-9abc-def012345678'),
    ),
  );

  _connections.onMessage = (peerId, json) {
    if (json['type'] == 'message') {
      final msg = ChatMessage.fromJson(json, _me.userId);
      if (msg != null) {
        _store.add(peerId, msg);
      }
    }

    if (!_appInForeground && json['type'] == 'message') {
      final text = json['text'] as String? ?? '';
      final from = json['from'] as String? ?? 'Someone';
      final peer =
          _discovery.peers.where((p) => p.userId == peerId).firstOrNull;
      final name = peer?.name ?? from;

      _notifications.show(
        peerId.hashCode,
        name,
        text,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'messages', 'Messages',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: jsonEncode({'peerId': peerId}),
      );
    }
  };

  runApp(const LocalChatApp());
}

class LocalChatApp extends StatefulWidget {
  const LocalChatApp({super.key});

  @override
  State<LocalChatApp> createState() => _LocalChatAppState();
}

class _LocalChatAppState extends State<LocalChatApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground =
        state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Chat',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomeScreen(
        me: _me,
        discovery: _discovery,
        connections: _connections,
        store: _store,
      ),
    );
  }
}
