import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_settings.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'home_screen.dart';
import 'lan_foreground.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'settings_screen.dart';
import 'transfer_manager.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

late DeviceInfo _me;
late DiscoveryService _discovery;
late ConnectionService _connections;
late MessageStore _store;
final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();
bool _appInForeground = true;

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerLanForegroundPort();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    const windowWidth = 420.0;
    const windowHeight = 720.0;
    await windowManager.setSize(const Size(windowWidth, windowHeight));
    await windowManager.setMinimumSize(const Size(360, 500));
    await windowManager.center();
    await windowManager.setTitle('Local Chat');
    await windowManager.setPreventClose(true);
    await windowManager.show();
  }

  await AppSettings.instance.init();
  _me = await DeviceInfo.load();
  _store = await MessageStore.init();
  _discovery = DiscoveryService(me: _me);
  _connections = ConnectionService(me: _me);
  await _connections.startServer();
  await _discovery.start();

  await TransferManager.instance.init(
    connections: _connections,
    store: _store,
    myId: _me.userId,
    notificationsPlugin: _notifications,
  );

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
    final type = json['type'] as String?;

    if (type == 'hello') {
      final name = json['name'] as String? ?? '';
      final peer =
          _discovery.peers.where((p) => p.userId == peerId).firstOrNull;
      if (peer != null) {
        _store.savePeerInfo(peerId, name, peer.ip, peer.port);
      }
    }

    if (type == 'message') {
      final msg = ChatMessage.fromJson(json, _me.userId);
      if (msg != null) {
        _store.add(peerId, msg);
      }
    }

    if (type == 'file_notify') {
      TransferManager.instance.registerIncoming(
        peerId,
        json['id'] as String? ?? '',
        json['name'] as String? ?? '',
        (json['size'] as num?)?.toInt() ?? 0,
      );
    }

    if (!_appInForeground &&
        !AppSettings.instance.notificationsMuted.value &&
        type == 'message') {
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

  TransferManager.instance.fileMessages.listen((event) {
    if (event.message.isMine) return;
    if (!_appInForeground &&
        !AppSettings.instance.notificationsMuted.value) {
      final peer =
          _discovery.peers.where((p) => p.userId == event.peerId).firstOrNull;
      final name = peer?.name ?? 'Someone';
      final fileName = event.message.attachmentName ?? 'a file';

      _notifications.show(
        event.peerId.hashCode,
        name,
        'Sent you $fileName',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'messages', 'Messages',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: jsonEncode({'peerId': event.peerId}),
      );
    }
  });

  runApp(const LocalChatApp());
}

/// Path relative to `data/flutter_assets/` — [tray_manager] builds the real path.
String _trayAssetPath() {
  if (Platform.isWindows) {
    return 'windows/runner/resources/app_icon.ico';
  }
  return 'assets/app_icon.png';
}

class LocalChatApp extends StatefulWidget {
  const LocalChatApp({super.key});

  @override
  State<LocalChatApp> createState() => _LocalChatAppState();
}

class _LocalChatAppState extends State<LocalChatApp>
    with WidgetsBindingObserver, TrayListener, WindowListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && Platform.isAndroid) {
      initLanForegroundTask();
    }
    if (_isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      WidgetsBinding.instance.addPostFrameCallback((_) => _initTray());
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    if (!_isDesktop) return;
    try {
      await trayManager.setIcon(_trayAssetPath());
      await trayManager.setToolTip('Local Chat');
      await trayManager.setContextMenu(Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Local Chat'),
          MenuItem(key: 'settings', label: 'Open Settings'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Close app'),
        ],
      ));
    } catch (_) {}
  }

  Future<void> _quitFromTray() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  void _openSettingsFromTray() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(store: _store),
      ),
    );
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
  }

  @override
  void onWindowClose() {
    if (_isDesktop) {
      unawaited(windowManager.hide());
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (!_isDesktop) return;
    unawaited(windowManager.show());
    unawaited(windowManager.focus());
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_isDesktop) return;
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(windowManager.show());
        unawaited(windowManager.focus());
        break;
      case 'settings':
        _openSettingsFromTray();
        break;
      case 'exit':
        unawaited(_quitFromTray());
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (!kIsWeb && Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        unawaited(startLanForegroundIfNeeded());
      } else if (state == AppLifecycleState.resumed) {
        unawaited(stopLanForeground());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeMode,
      builder: (_, mode, child) {
        return MaterialApp(
          navigatorKey: appNavigatorKey,
          title: 'Local Chat',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
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
      },
    );
  }
}
