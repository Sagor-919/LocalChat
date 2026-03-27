import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'android_share_receiver.dart';
import 'app_branding.dart';
import 'app_settings.dart';
import 'chat_screen.dart';
import 'connection_service.dart';
import 'device.dart';
import 'first_launch_prompt.dart';
import 'discovery_service.dart';
import 'home_screen.dart';
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

/// Desktop: show message toasts when the window is hidden or minimized.
bool _desktopNotifyIncomingMessages = false;

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

PeerDevice? _discoveryPeerById(String peerId) {
  for (final p in _discovery.peers) {
    if (p.userId == peerId) return p;
  }
  return null;
}

Future<void> _syncDesktopNotifyForIncomingMessages() async {
  if (!_isDesktop) return;
  try {
    final vis = await windowManager.isVisible();
    final min = await windowManager.isMinimized();
    final focused = await windowManager.isFocused();
    _desktopNotifyIncomingMessages = !vis || min || !focused;

    if (Platform.isWindows && vis && !min && focused) {
      try {
        await windowManager.setProgressBar(-1);
      } catch (_) {}
    }
  } catch (_) {}
}

/// Windows taskbar “pulse” (indeterminate progress bar under the icon) when
/// the window is not in the foreground — includes minimized, tray-hidden, and
/// unfocused (another app on top).
Future<void> _pulseWindowsTaskbarForAttention() async {
  if (!_isDesktop || !Platform.isWindows) return;
  try {
    final vis = await windowManager.isVisible();
    final min = await windowManager.isMinimized();
    final focused = await windowManager.isFocused();
    if (!vis || min || !focused) {
      await windowManager.setProgressBar(2);
    }
  } catch (_) {}
}

String? _parsePeerIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>?;
    final id = map?['peerId'] as String?;
    if (id == null || id.isEmpty) return null;
    return id;
  } catch (_) {
    return null;
  }
}

Future<PeerDevice?> _peerDeviceFromStore(String peerId) async {
  final infos = await _store.loadAllPeerInfos();
  final info = infos[peerId];
  if (info == null) return null;
  return PeerDevice(
    userId: peerId,
    name: info['name'] as String? ?? 'Unknown',
    ip: info['ip'] as String? ?? '',
    port: (info['port'] as num?)?.toInt() ?? ConnectionService.tcpPort,
    lastSeen: DateTime.now(),
  );
}

/// Show desktop window (from tray/minimized), then open the chat for [peerId].
Future<void> openChatFromNotificationPayload(String peerId) async {
  if (peerId.isEmpty) return;

  if (_isDesktop) {
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;

  PeerDevice? peer = _discoveryPeerById(peerId);
  peer ??= await _peerDeviceFromStore(peerId);
  if (peer == null) {
    debugPrint('LocalChat: no peer metadata for $peerId');
    return;
  }

  if (!ctx.mounted) return;
  Navigator.of(ctx).popUntil((route) => route.isFirst);
  if (!ctx.mounted) return;
  await Navigator.of(ctx).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        me: _me,
        peer: peer!,
        discovery: _discovery,
        connections: _connections,
        store: _store,
      ),
    ),
  );

  if (_isDesktop) {
    unawaited(_syncDesktopNotifyForIncomingMessages());
  }
}

void _onNotificationTapped(NotificationResponse response) {
  if (response.notificationResponseType !=
      NotificationResponseType.selectedNotification) {
    return;
  }
  final peerId = _parsePeerIdFromPayload(response.payload);
  if (peerId == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(openChatFromNotificationPayload(peerId));
  });
}

Future<void> _tryOpenChatFromColdStartNotification() async {
  try {
    final details = await _notifications.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final r = details!.notificationResponse;
    if (r == null ||
        r.notificationResponseType !=
            NotificationResponseType.selectedNotification) {
      return;
    }
    final peerId = _parsePeerIdFromPayload(r.payload);
    if (peerId == null) return;
    await openChatFromNotificationPayload(peerId);
  } catch (e, st) {
    debugPrint('Launch notification handling failed: $e\n$st');
  }
}

bool _shouldAlertIncomingMessage() {
  if (_isDesktop) return _desktopNotifyIncomingMessages;
  return !_appInForeground;
}

NotificationDetails _incomingMessageNotificationDetails() {
  return NotificationDetails(
    android: const AndroidNotificationDetails(
      'messages',
      'Messages',
      importance: Importance.high,
      priority: Priority.high,
    ),
    linux: const LinuxNotificationDetails(),
    windows: const WindowsNotificationDetails(
      duration: WindowsNotificationDuration.long,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AndroidShareReceiver.installPushHandler();

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    // Initializes ITaskbarList3; required before setProgressBar / taskbar APIs.
    await windowManager.waitUntilReadyToShow();
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

  try {
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
            appName: 'Local Chat',
            appUserModelId: 'com.localchat.app',
            guid: 'd3c1f8a0-1234-5678-9abc-def012345678'),
      ),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  } catch (e, st) {
    debugPrint('Local notifications init failed: $e\n$st');
  }

  _connections.onMessage = (peerId, json) {
    final type = json['type'] as String?;

    if (type == 'hello') {
      final name = (json['name'] as String? ?? '').trim();
      final peer = _discoveryPeerById(peerId);
      final sock = _connections.getSocket(peerId);
      final ip = (peer?.ip ?? sock?.remoteAddress.address ?? '').trim();
      final port = peer?.port ?? ConnectionService.tcpPort;
      final displayName = name.isNotEmpty
          ? name
          : ((peer?.name ?? '').trim().isNotEmpty ? peer!.name : 'Peer');
      unawaited(_store.savePeerInfo(peerId, displayName, ip, port));
    }

    if (type == 'message') {
      final msg = ChatMessage.fromJson(json, _me.userId);
      if (msg != null) {
        final peer = _discoveryPeerById(peerId);
        unawaited(_store.add(
          peerId,
          msg,
          peerDisplayName: peer?.name,
          peerIp: peer?.ip,
          peerTcpPort: peer?.port,
        ));
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

    if (_shouldAlertIncomingMessage() &&
        !AppSettings.instance.notificationsMuted.value &&
        type == 'message') {
      final text = json['text'] as String? ?? '';
      final from = json['from'] as String? ?? 'Someone';
      final peer = _discoveryPeerById(peerId);
      final name = peer?.name ?? from;

      _notifications.show(
        peerId.hashCode,
        name,
        text,
        _incomingMessageNotificationDetails(),
        payload: jsonEncode({'peerId': peerId}),
      );
      unawaited(_pulseWindowsTaskbarForAttention());
    }
  };

  TransferManager.instance.fileMessages.listen((event) {
    if (event.message.isMine) return;
    if (_shouldAlertIncomingMessage() &&
        !AppSettings.instance.notificationsMuted.value) {
      final peer = _discoveryPeerById(event.peerId);
      final name = peer?.name ?? 'Someone';
      final fileName = event.message.attachmentName ?? 'a file';

      _notifications.show(
        event.peerId.hashCode,
        name,
        'Sent you $fileName',
        _incomingMessageNotificationDetails(),
        payload: jsonEncode({'peerId': event.peerId}),
      );
      unawaited(_pulseWindowsTaskbarForAttention());
    }
  });

  runApp(const LocalChatApp());
}

/// Path relative to `data/flutter_assets/` — [tray_manager] builds the real path.
String _trayAssetPath() {
  if (Platform.isWindows) {
    return 'windows/runner/resources/app_icon.ico';
  }
  return AppAssets.appIcon;
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
      AndroidShareReceiver.onSharesPulled = _onAndroidSharesArrived;
    }
    if (_isDesktop) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _initTray();
        await _syncDesktopNotifyForIncomingMessages();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final ctx = appNavigatorKey.currentContext;
          if (ctx != null && ctx.mounted) {
            await showFirstLaunchOnboardingIfNeeded(ctx);
          }
          unawaited(_tryOpenChatFromColdStartNotification());
        });
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ctx = appNavigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          await showFirstLaunchOnboardingIfNeeded(ctx);
        }
        if (!mounted) return;
        await AndroidShareReceiver.pullPendingFromPlatform();
        unawaited(_tryOpenChatFromColdStartNotification());
      });
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isAndroid) {
      AndroidShareReceiver.onSharesPulled = null;
    }
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
    unawaited(() async {
      await windowManager.show();
      await windowManager.focus();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _syncDesktopNotifyForIncomingMessages();
    }());
  }

  @override
  void onWindowClose() {
    if (!_isDesktop) return;
    if (AppSettings.instance.desktopRunInBackground.value) {
      unawaited(windowManager.hide());
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        unawaited(_syncDesktopNotifyForIncomingMessages());
      });
    } else {
      unawaited(_quitFromTray());
    }
  }

  @override
  void onWindowMinimize() {
    if (_isDesktop) unawaited(_syncDesktopNotifyForIncomingMessages());
  }

  @override
  void onWindowRestore() {
    if (_isDesktop) unawaited(_syncDesktopNotifyForIncomingMessages());
  }

  @override
  void onWindowFocus() {
    if (_isDesktop) unawaited(_syncDesktopNotifyForIncomingMessages());
  }

  @override
  void onWindowBlur() {
    if (_isDesktop) unawaited(_syncDesktopNotifyForIncomingMessages());
  }

  @override
  void onTrayIconMouseDown() {
    if (!_isDesktop) return;
    unawaited(() async {
      await windowManager.show();
      await windowManager.focus();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _syncDesktopNotifyForIncomingMessages();
    }());
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
        unawaited(() async {
          await windowManager.show();
          await windowManager.focus();
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await _syncDesktopNotifyForIncomingMessages();
        }());
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
    if (state == AppLifecycleState.resumed && !kIsWeb && Platform.isAndroid) {
      unawaited(AndroidShareReceiver.pullPendingFromPlatform());
    }
  }

  void _onAndroidSharesArrived(int count) {
    if (!mounted || count <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showAndroidShareSnackBarForArrival(count);
    });
  }

  void _showAndroidShareSnackBarForArrival(int count) {
    if (kIsWeb || !Platform.isAndroid || count <= 0) return;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final inChat = ChatScreen.openChatSessions > 0;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          inChat
              ? (count == 1
                  ? 'Shared file added to attachments.'
                  : '$count shared files added to attachments.')
              : (count == 1
                  ? '1 shared file ready — open a chat to add it to the composer.'
                  : '$count shared files ready — open a chat to add them to the composer.'),
        ),
      ),
    );
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
