import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static final instance = AppSettings._();
  AppSettings._();

  static const _kFirstLaunchOnboardingComplete = 'first_launch_onboarding_complete';
  /// Legacy key from notification-only first run; counts as onboarding done.
  static const _kFirstLaunchPermissionsDone = 'first_launch_permissions_done';

  late SharedPreferences _prefs;

  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final notificationsMuted = ValueNotifier<bool>(false);
  final downloadPath = ValueNotifier<String>('');
  final startWithWindows = ValueNotifier<bool>(false);
  /// Desktop: when true, closing the window hides to tray and keeps LAN active; when false, exit the app.
  final desktopRunInBackground = ValueNotifier<bool>(true);

  /// WAN presence (WebSocket + STUN). LAN discovery unchanged when false.
  final globalDiscoveryEnabled = ValueNotifier<bool>(false);
  final signalingServerUrl = ValueNotifier<String>('');
  final stunHost = ValueNotifier<String>('stun.l.google.com');
  final stunPort = ValueNotifier<int>(19302);

  /// If non-empty, replaces STUN for the public address (`wip`) sent to signaling.
  final wanManualPublicIp = ValueNotifier<String>('');
  /// 0 = use [ConnectionService.tcpPort] in `reg`; else advertised WAN chat port.
  final wanAdvertisedChatTcpPort = ValueNotifier<int>(0);
  /// 0 = use [kFileTransferPort] in `reg`; else advertised WAN file port.
  final wanAdvertisedFileTcpPort = ValueNotifier<int>(0);

  /// When true (default), try UPnP to open chat/file TCP on the router if both advertised ports are 0.
  final upnpPortMappingEnabled = ValueNotifier<bool>(true);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final modeStr = _prefs.getString('theme_mode') ?? 'system';
    themeMode.value = switch (modeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notificationsMuted.value = _prefs.getBool('notifications_muted') ?? false;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      desktopRunInBackground.value =
          _prefs.getBool('desktop_run_in_background') ?? true;
    }

    final savedPath = _prefs.getString('download_path');
    if (savedPath == null || savedPath.isEmpty) {
      final path = await ensureLocalChatDownloadDirectory();
      downloadPath.value = path;
      await _prefs.setString('download_path', path);
    } else {
      downloadPath.value = savedPath;
      try {
        await Directory(savedPath).create(recursive: true);
      } catch (_) {}
    }

    if (Platform.isWindows) {
      startWithWindows.value = await _readStartupRegistry();
    }

    globalDiscoveryEnabled.value =
        _prefs.getBool('global_discovery_enabled') ?? false;
    signalingServerUrl.value =
        _prefs.getString('signaling_server_url') ?? '';
    stunHost.value = _prefs.getString('stun_host') ?? 'stun.l.google.com';
    stunPort.value = _prefs.getInt('stun_port') ?? 19302;
    wanManualPublicIp.value = _prefs.getString('wan_manual_public_ip') ?? '';
    wanAdvertisedChatTcpPort.value =
        _prefs.getInt('wan_adv_chat_tcp') ?? 0;
    wanAdvertisedFileTcpPort.value =
        _prefs.getInt('wan_adv_file_tcp') ?? 0;
    upnpPortMappingEnabled.value =
        _prefs.getBool('upnp_port_mapping_enabled') ?? true;
  }

  Future<void> setGlobalDiscoveryEnabled(bool v) async {
    globalDiscoveryEnabled.value = v;
    await _prefs.setBool('global_discovery_enabled', v);
  }

  Future<void> setSignalingServerUrl(String v) async {
    signalingServerUrl.value = v;
    await _prefs.setString('signaling_server_url', v.trim());
  }

  Future<void> setStunHost(String v) async {
    stunHost.value = v.trim();
    await _prefs.setString('stun_host', stunHost.value);
  }

  Future<void> setStunPort(int v) async {
    stunPort.value = v.clamp(1, 65535);
    await _prefs.setInt('stun_port', stunPort.value);
  }

  Future<void> setWanManualPublicIp(String v) async {
    wanManualPublicIp.value = v.trim();
    await _prefs.setString('wan_manual_public_ip', wanManualPublicIp.value);
  }

  /// 0 means use [ConnectionService.tcpPort].
  Future<void> setWanAdvertisedChatTcpPort(int v) async {
    wanAdvertisedChatTcpPort.value = v.clamp(0, 65535);
    await _prefs.setInt('wan_adv_chat_tcp', wanAdvertisedChatTcpPort.value);
  }

  /// 0 means use [kFileTransferPort].
  Future<void> setWanAdvertisedFileTcpPort(int v) async {
    wanAdvertisedFileTcpPort.value = v.clamp(0, 65535);
    await _prefs.setInt('wan_adv_file_tcp', wanAdvertisedFileTcpPort.value);
  }

  Future<void> setUpnpPortMappingEnabled(bool v) async {
    upnpPortMappingEnabled.value = v;
    await _prefs.setBool('upnp_port_mapping_enabled', v);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final str = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    };
    await _prefs.setString('theme_mode', str);
  }

  Future<void> setNotificationsMuted(bool muted) async {
    notificationsMuted.value = muted;
    await _prefs.setBool('notifications_muted', muted);
  }

  Future<void> setDesktopRunInBackground(bool enabled) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    desktopRunInBackground.value = enabled;
    await _prefs.setBool('desktop_run_in_background', enabled);
  }

  Future<void> setDownloadPath(String path) async {
    downloadPath.value = path;
    await _prefs.setString('download_path', path);
  }

  /// True after first-run welcome (notifications, storage on Android, download location).
  bool get firstLaunchOnboardingComplete =>
      _prefs.getBool(_kFirstLaunchOnboardingComplete) == true ||
      _prefs.getBool(_kFirstLaunchPermissionsDone) == true;

  Future<void> setFirstLaunchOnboardingComplete() async {
    await _prefs.setBool(_kFirstLaunchOnboardingComplete, true);
    await _prefs.setBool(_kFirstLaunchPermissionsDone, true);
  }

  Future<void> setStartWithWindows(bool enabled) async {
    if (!Platform.isWindows) return;
    startWithWindows.value = enabled;
    final exe = Platform.resolvedExecutable;
    /// Logon startup: pass `--autostart` so [main] can hide the window and stay in tray only.
    final runValue = '"$exe" --autostart';
    if (enabled) {
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v', 'LocalChat',
        '/t', 'REG_SZ',
        '/d', runValue,
        '/f',
      ]);
    } else {
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v', 'LocalChat',
        '/f',
      ]);
    }
  }

  static Future<bool> _readStartupRegistry() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v', 'LocalChat',
      ]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Default save folder: `…/LocalChat Folder/Downloads` (received files live under Downloads).
  static Future<String> ensureLocalChatDownloadDirectory() async {
    const rootName = 'LocalChat Folder';
    const downloadsName = 'Downloads';
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final downloads = await getDownloadsDirectory();
      final base = downloads?.path ?? Directory.systemTemp.path;
      final root = Directory(p.join(base, rootName));
      await root.create(recursive: true);
      final dir = Directory(p.join(root.path, downloadsName));
      await dir.create(recursive: true);
      return dir.path;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      final docDir = await getApplicationDocumentsDirectory();
      final root = Directory(p.join(docDir.path, rootName));
      await root.create(recursive: true);
      final dir = Directory(p.join(root.path, downloadsName));
      await dir.create(recursive: true);
      return dir.path;
    }
    final root = Directory(p.join(Directory.systemTemp.path, rootName));
    await root.create(recursive: true);
    final dir = Directory(p.join(root.path, downloadsName));
    await dir.create(recursive: true);
    return dir.path;
  }
}
