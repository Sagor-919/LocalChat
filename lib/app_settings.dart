import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static final instance = AppSettings._();
  AppSettings._();

  static const _kFirstLaunchOnboardingComplete =
      'first_launch_onboarding_complete';

  /// Legacy key from notification-only first run; counts as onboarding done.
  static const _kFirstLaunchPermissionsDone = 'first_launch_permissions_done';
  static const _kGlobalDiscoveryEnabled = 'global_discovery_enabled';
  static const _kGlobalDiscoveryRelays = 'global_discovery_relays';
  static const defaultGlobalDiscoveryRelays = <String>[
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
    'wss://nostr.wine',
    'wss://relay.snort.social',
  ];

  late SharedPreferences _prefs;

  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final notificationsMuted = ValueNotifier<bool>(false);
  final downloadPath = ValueNotifier<String>('');
  final startWithWindows = ValueNotifier<bool>(false);
  final globalDiscoveryEnabled = ValueNotifier<bool>(false);
  final globalDiscoveryRelays = ValueNotifier<List<String>>(
    defaultGlobalDiscoveryRelays,
  );

  /// Desktop: when true, closing the window hides to tray and keeps LAN active; when false, exit the app.
  final desktopRunInBackground = ValueNotifier<bool>(true);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final modeStr = _prefs.getString('theme_mode') ?? 'system';
    themeMode.value = switch (modeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notificationsMuted.value = _prefs.getBool('notifications_muted') ?? false;
    globalDiscoveryEnabled.value =
        _prefs.getBool(_kGlobalDiscoveryEnabled) ?? false;
    globalDiscoveryRelays.value = _sanitizeRelays(
      _prefs.getStringList(_kGlobalDiscoveryRelays),
    );

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      desktopRunInBackground.value =
          _prefs.getBool('desktop_run_in_background') ?? true;
    }

    if (kIsWeb) {
      // Web has no filesystem download path; downloads go through the
      // browser. Skip dart:io directory creation entirely.
      downloadPath.value = _prefs.getString('download_path') ?? '';
    } else {
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
    }

    if (!kIsWeb && Platform.isWindows) {
      startWithWindows.value = await _readStartupRegistry();
    }
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

  Future<void> setGlobalDiscoveryEnabled(bool enabled) async {
    globalDiscoveryEnabled.value = enabled;
    await _prefs.setBool(_kGlobalDiscoveryEnabled, enabled);
  }

  Future<void> setGlobalDiscoveryRelays(List<String> relays) async {
    final sanitized = _sanitizeRelays(relays);
    globalDiscoveryRelays.value = sanitized;
    await _prefs.setStringList(_kGlobalDiscoveryRelays, sanitized);
  }

  Future<void> setDesktopRunInBackground(bool enabled) async {
    if (kIsWeb ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
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
    if (kIsWeb || !Platform.isWindows) return;
    startWithWindows.value = enabled;
    final exe = Platform.resolvedExecutable;

    /// Logon startup: pass `--autostart` so [main] can hide the window and stay in tray only.
    final runValue = '"$exe" --autostart';
    if (enabled) {
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'LocalChat',
        '/t',
        'REG_SZ',
        '/d',
        runValue,
        '/f',
      ]);
    } else {
      await Process.run('reg', [
        'delete',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'LocalChat',
        '/f',
      ]);
    }
  }

  static Future<bool> _readStartupRegistry() async {
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v',
        'LocalChat',
      ]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Default save folder: `…/LocalChat Folder/Downloads` (received files live under Downloads).
  static List<String> _sanitizeRelays(List<String>? relays) {
    final seen = <String>{};
    final out = <String>[];
    for (final relay in relays ?? defaultGlobalDiscoveryRelays) {
      final trimmed = relay.trim();
      if (trimmed.isEmpty || seen.contains(trimmed)) continue;
      final uri = Uri.tryParse(trimmed);
      if (uri == null || (uri.scheme != 'wss' && uri.scheme != 'ws')) {
        continue;
      }
      seen.add(trimmed);
      out.add(trimmed);
    }
    return out.isEmpty ? defaultGlobalDiscoveryRelays : out;
  }

  static Future<String> ensureLocalChatDownloadDirectory() async {
    if (kIsWeb) return '';
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
