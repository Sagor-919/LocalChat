import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'app_branding.dart';
import 'app_settings.dart';
import 'app_splash.dart';
import 'android_share_inbound.dart';
import 'chat_crypto.dart';
import 'chat_screen.dart';
import 'connection_service.dart';
import 'desktop_drop_queue.dart';
import 'device.dart';
import 'staged_from_drop.dart';
import 'first_launch_prompt.dart';
import 'discovery_service.dart';
import 'home_screen.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'settings_screen.dart';
import 'transfer_manager.dart';
import 'windows_taskbar_flash.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

late DeviceInfo _me;
late DiscoveryService _discovery;
late ConnectionService _connections;
late MessageStore _store;
StreamSubscription<FileMessageEvent>? _fileMessagesSub;
final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();
bool _appInForeground = true;

/// Set from `main` args on Windows when launched from HKCU\...\Run with `--autostart`.
bool _windowsAutostartLaunch = false;

/// If true, [showFirstLaunchOnboardingIfNeeded] runs on first tray/window show instead of cold start.
bool _deferOnboardingUntilWindowShown = false;

/// Last connectivity snapshot for online/offline edge detection.
List<ConnectivityResult>? _lastConnectivityResults;

bool _connectivityIsOffline(List<ConnectivityResult> results) {
  return results.length == 1 && results.first == ConnectivityResult.none;
}

/// After a real network drop, TCP sockets can be zombies and UDP receive can
/// stick to a dead interface — same as restarting the app. Clear chat sockets
/// then rebind discovery so home + chat can reconnect without restart.
Future<void> _restoreLanAfterLinkRecovery() async {
  await _connections.disconnectAllPeers();
  await _discovery.rebindUdpSocket();
}

void _onConnectivityChanged(List<ConnectivityResult> results) {
  final offline = _connectivityIsOffline(results);
  final wasOffline =
      _lastConnectivityResults != null &&
      _connectivityIsOffline(_lastConnectivityResults!);
  _lastConnectivityResults = List<ConnectivityResult>.from(results);

  if (offline && !wasOffline) {
    unawaited(_connections.disconnectAllPeers());
  } else if (!offline && wasOffline) {
    unawaited(_restoreLanAfterLinkRecovery());
  }
}

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

/// Windows taskbar "pulse" (indeterminate progress bar under the icon) when
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

/// Windows toast XML passes the payload in a `launch` attribute; JSON with `"` breaks
/// the attribute and the native layer often delivers an empty payload. Use a plain
/// [peerId] string in the payload on Windows (see [_notificationPayloadForPeer]).
String? _parsePeerIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  final trimmed = payload.trim();
  if (trimmed.startsWith('{')) {
    try {
      final map = jsonDecode(trimmed) as Map<String, dynamic>?;
      final id = map?['peerId'] as String?;
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {}
    return null;
  }
  return trimmed.isNotEmpty ? trimmed : null;
}

String _notificationPayloadForPeer(String peerId) {
  if (Platform.isWindows) {
    return peerId;
  }
  return jsonEncode({'peerId': peerId});
}

String? _peerIdFromNotificationResponse(NotificationResponse r) {
  var p = _parsePeerIdFromPayload(r.payload);
  if (p != null) return p;
  if (r.data.isEmpty) return null;
  for (final key in <String>['payload', 'launch', 'Payload', 'Launch']) {
    final v = r.data[key];
    if (v is String) {
      p = _parsePeerIdFromPayload(v);
      if (p != null) return p;
    }
  }
  return null;
}

bool _isOpenChatNotificationTap(NotificationResponse r) {
  if (r.notificationResponseType ==
      NotificationResponseType.selectedNotification) {
    return true;
  }
  if (Platform.isWindows &&
      r.notificationResponseType ==
          NotificationResponseType.selectedNotificationAction) {
    return true;
  }
  return false;
}

Future<void> _handleIncomingEncryptedMessage(
  String peerId,
  Map<String, dynamic> json,
) async {
  final ct = json['ct'] as String?;
  if (ct == null || ct.isEmpty) return;
  final (text, _) = await ChatCrypto.decryptMessage(_me.userId, peerId, ct);
  if (text == null) return;
  final msg = ChatMessage(
    id: json['id'] as String? ?? '',
    senderId: json['from'] as String? ?? '',
    text: text,
    timestamp:
        (json['time'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch,
    isMine: (json['from'] as String?) == _me.userId,
  );
  await _handleIncomingTextMessage(peerId, msg);
}

Future<void> _handleIncomingTextMessage(String peerId, ChatMessage msg) async {
  // Ack first so duplicate resends (same id) still clear the sender's pending state.
  _connections.sendJson(peerId, {'type': 'message_ack', 'id': msg.id});

  final peer = _discoveryPeerById(peerId);
  final inserted = await _store.add(
    peerId,
    msg,
    peerDisplayName: peer?.name,
    peerIp: peer?.ip,
    peerTcpPort: peer?.port,
  );
  if (inserted &&
      _shouldAlertIncomingMessage() &&
      !AppSettings.instance.notificationsMuted.value) {
    final name = peer?.name ?? 'Someone';
    _notifications.show(
      peerId.hashCode,
      name,
      msg.text,
      _incomingMessageNotificationDetails(),
      payload: _notificationPayloadForPeer(peerId),
    );
    unawaited(_pulseWindowsTaskbarForAttention());
    flashWindowsTaskbarIcon();
  }
}

/// Receiver acknowledged [messageId]; we confirm back so both sides agree delivery completed.
Future<void> _completeDeliveryHandshake(
  String peerId,
  String messageId,
) async {
  final ok = _connections.sendJson(peerId, {
    'type': 'message_ack_confirm',
    'id': messageId,
    'from': _me.userId,
  });
  if (ok) {
    await _store.updateDeliveryState(
      peerId,
      messageId,
      MessageDelivery.delivered,
    );
  } else {
    await _store.updateDeliveryState(
      peerId,
      messageId,
      MessageDelivery.awaitingConfirm,
    );
  }
}

Future<PeerDevice?> _peerDeviceFromStore(String peerId) async {
  final infos = await _store.loadAllPeerInfos();
  final info = infos[peerId];
  if (info == null) return null;
  final tag = info['lan_stable_tag'] as String?;
  return PeerDevice(
    userId: peerId,
    name: info['name'] as String? ?? 'Unknown',
    ip: info['ip'] as String? ?? '',
    port: (info['port'] as num?)?.toInt() ?? ConnectionService.tcpPort,
    lastSeen: DateTime.now(),
    lanStableTag: tag != null && tag.isNotEmpty ? tag : null,
  );
}

Future<void> _maybePresentDeferredOnboarding() async {
  if (!_deferOnboardingUntilWindowShown) return;
  if (AppSettings.instance.firstLaunchOnboardingComplete) {
    _deferOnboardingUntilWindowShown = false;
    return;
  }
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  _deferOnboardingUntilWindowShown = false;
  await showFirstLaunchOnboardingIfNeeded(ctx);
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
    await _maybePresentDeferredOnboarding();
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
  if (!_isOpenChatNotificationTap(response)) {
    return;
  }
  final peerId = _peerIdFromNotificationResponse(response);
  if (peerId == null) {
    debugPrint(
      'LocalChat: notification tap with no peer id (payload=${response.payload})',
    );
    return;
  }
  void run() {
    if (_isDesktop && Platform.isWindows) {
      unawaited(_ensureWindowVisibleThenOpenChat(peerId));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(openChatFromNotificationPayload(peerId));
      });
    }
  }

  if (Platform.isWindows && _isDesktop) {
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  } else {
    run();
  }
}

/// Windows: notification taps can fire before the navigator is mounted; activate the window
/// and poll briefly for [appNavigatorKey] before navigating.
Future<void> _ensureWindowVisibleThenOpenChat(String peerId) async {
  try {
    await windowManager.show();
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
    var retries = 0;
    while (appNavigatorKey.currentContext == null && retries < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      retries++;
    }
    await openChatFromNotificationPayload(peerId);
  } catch (e, st) {
    debugPrint('Windows notification tap failed: $e\n$st');
  }
}

Future<void> _tryOpenChatFromColdStartNotification() async {
  try {
    final details = await _notifications.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return;
    final r = details!.notificationResponse;
    if (r == null || !_isOpenChatNotificationTap(r)) {
      return;
    }
    final peerId = _peerIdFromNotificationResponse(r);
    if (peerId == null) return;
    if (_isDesktop && Platform.isWindows) {
      await _ensureWindowVisibleThenOpenChat(peerId);
    } else {
      await openChatFromNotificationPayload(peerId);
    }
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

/// Notifications plugin init is best-effort: failures should never block startup.
Future<void> _initNotificationsSafe() async {
  try {
    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'Local Chat',
          appUserModelId: 'com.localchat.app',
          guid: 'd3c1f8a0-1234-5678-9abc-def012345678',
        ),
      ),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  } catch (e, st) {
    debugPrint('Local notifications init failed: $e\n$st');
  }
}

/// Heavy bootstrap: settings, device info, message store, sockets, notifications,
/// file transfer. Runs from [_LocalChatAppState] behind the splash so the first
/// frame paints before any blocking I/O.
Future<void> _bootstrapServices() async {
  await AppSettings.instance.init();
  if (!kIsWeb && Platform.isWindows && _windowsAutostartLaunch) {
    _deferOnboardingUntilWindowShown =
        !AppSettings.instance.firstLaunchOnboardingComplete;
  }

  // Device info and message store are independent — run in parallel.
  final (me, store) = await (DeviceInfo.load(), MessageStore.init()).wait;
  _me = me;
  _store = store;

  _discovery = DiscoveryService(me: _me);
  _connections = ConnectionService(me: _me);
  _discovery.hasActiveChatTcp = (id) => _connections.isConnected(id);
  await _connections.startServer();
  await _discovery.start();

  _connections.onIncomingConnection = (socket, peerId) {
    final addr = socket.remoteAddress;
    if (addr.type != InternetAddressType.IPv4) return;
    final peer = _discoveryPeerById(peerId);
    _discovery.rememberPeerFromTcp(
      userId: peerId,
      name: (peer?.name ?? '').trim().isNotEmpty ? peer!.name : 'Peer',
      ip: addr.address,
      port: peer?.port ?? ConnectionService.tcpPort,
      lanStableTag: peer?.lanStableTag,
    );
  };

  await TransferManager.instance.init(
    connections: _connections,
    store: _store,
    myId: _me.userId,
    notificationsPlugin: _notifications,
  );

  await _initNotificationsSafe();

  _connections.onMessage = (peerId, json) {
    final type = json['type'] as String?;

    if (type == 'ping') {
      final id = json['id'] as String?;
      if (id != null) _connections.handleIncomingPing(peerId, id);
      return;
    }
    if (type == 'pong') {
      final id = json['id'] as String?;
      if (id != null) _connections.handlePong(peerId, id);
      return;
    }

    if (type == 'hello') {
      final name = (json['name'] as String? ?? '').trim();
      final peer = _discoveryPeerById(peerId);
      final sock = _connections.getSocket(peerId);
      final ip = (peer?.ip ?? sock?.remoteAddress.address ?? '').trim();
      final port = peer?.port ?? ConnectionService.tcpPort;
      final displayName = name.isNotEmpty
          ? name
          : ((peer?.name ?? '').trim().isNotEmpty ? peer!.name : 'Peer');
      if (ip.isNotEmpty) {
        _discovery.rememberPeerFromTcp(
          userId: peerId,
          name: displayName,
          ip: ip,
          port: port,
          lanStableTag: peer?.lanStableTag,
        );
      }
      unawaited(_store.savePeerInfo(
        peerId,
        displayName,
        ip,
        port,
        lanStableTag: peer?.lanStableTag,
      ));
      return;
    }

    if (type == 'message_ack_confirm') {
      // Original receiver: sender confirmed they recorded delivery after our message_ack.
      return;
    }

    if (type == 'message_ack') {
      final id = json['id'] as String?;
      if (id != null && id.isNotEmpty) {
        unawaited(_completeDeliveryHandshake(peerId, id));
      }
      return;
    }

    if (type == 'message') {
      final enc = json['enc'] == true;
      if (enc) {
        unawaited(_handleIncomingEncryptedMessage(peerId, json));
      } else {
        final msg = ChatMessage.fromJson(json, _me.userId);
        if (msg != null) {
          unawaited(_handleIncomingTextMessage(peerId, msg));
        }
      }
      return;
    }

    if (type == 'file_notify') {
      TransferManager.instance.registerIncoming(
        peerId,
        json['id'] as String? ?? '',
        json['name'] as String? ?? '',
        (json['size'] as num?)?.toInt() ?? 0,
      );
    }

    if (type == 'file_control') {
      final id = json['id'] as String?;
      if (id == null || id.isEmpty) return;
      final from = json['from'] as String? ?? '';
      if (json['pause'] == true) {
        if (from == 'sender') {
          TransferManager.instance.handleRemotePauseIncoming(id);
        } else if (from == 'receiver') {
          TransferManager.instance.handleRemotePauseOutgoing(id);
        }
      }
      return;
    }
  };

  _fileMessagesSub = TransferManager.instance.fileMessages.listen((event) {
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
        payload: _notificationPayloadForPeer(event.peerId),
      );
      unawaited(_pulseWindowsTaskbarForAttention());
      flashWindowsTaskbarIcon();
    }
  });
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ---- Synchronous-ish prelude (~tens of ms) ----
  // Goal: reach [runApp] as fast as possible so the splash paints first.
  // Heavy I/O (sqlite, sockets, notifications) moves to [_bootstrapServices].

  if (!kIsWeb && Platform.isWindows) {
    _windowsAutostartLaunch = args.contains('--autostart');
  }

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--share-file' && i + 1 < args.length) {
        final p = args[++i];
        if (p.isNotEmpty && stagedDropPathExists(p)) {
          DesktopDropQueue.enqueue([p]);
        }
      }
    }
  }

  if (_isDesktop) {
    try {
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
      if (Platform.isWindows && _windowsAutostartLaunch) {
        await windowManager.hide();
      } else {
        await windowManager.show();
      }
    } catch (e, st) {
      debugPrint('Window manager init failed: $e\n$st');
    }
  }

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
  bool _ready = false;
  Object? _bootError;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _bootstrapServices();
      if (!mounted) return;
      setState(() => _ready = true);

      final connectivity = Connectivity();
      _connectivitySub = connectivity.onConnectivityChanged
          .listen(_onConnectivityChanged);
      unawaited(
        connectivity.checkConnectivity().then(_onConnectivityChanged),
      );
      WidgetsBinding.instance.addObserver(this);

      if (_isDesktop) {
        windowManager.addListener(this);
        trayManager.addListener(this);
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await _initTray();
          await _syncDesktopNotifyForIncomingMessages();
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final ctx = appNavigatorKey.currentContext;
            if (ctx != null &&
                ctx.mounted &&
                !_deferOnboardingUntilWindowShown) {
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
          if (!kIsWeb && Platform.isAndroid) {
            await AndroidShareInbound.syncFromNative();
          }
          unawaited(_tryOpenChatFromColdStartNotification());
        });
      }
    } catch (e, st) {
      debugPrint('Bootstrap failed: $e\n$st');
      if (!mounted) return;
      setState(() => _bootError = e);
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _fileMessagesSub?.cancel();
    TransferManager.instance.dispose();
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
      await _maybePresentDeferredOnboarding();
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
    if (!_isDesktop) return;
    unawaited(() async {
      await _maybePresentDeferredOnboarding();
      await _syncDesktopNotifyForIncomingMessages();
    }());
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
      await _maybePresentDeferredOnboarding();
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
          await _maybePresentDeferredOnboarding();
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
    if (!kIsWeb && Platform.isAndroid) {
      if (state == AppLifecycleState.paused) {
        if (_ready && _connections.hasActiveTcpPeers) {
          unawaited(WakelockPlus.enable());
        }
      } else if (state == AppLifecycleState.resumed) {
        unawaited(WakelockPlus.disable());
      }
    }
    if (state == AppLifecycleState.resumed && _ready) {
      unawaited(_discovery.recoverAfterNetworkOrResume());
      if (!kIsWeb && Platform.isAndroid) {
        unawaited(AndroidShareInbound.syncFromNative());
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
          home: _bootError != null
              ? AppBootError(error: _bootError!)
              : !_ready
                  ? const AppSplash()
                  : HomeScreen(
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
