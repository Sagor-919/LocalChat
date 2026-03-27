import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static final instance = AppSettings._();
  AppSettings._();

  late SharedPreferences _prefs;

  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final notificationsMuted = ValueNotifier<bool>(false);
  final downloadPath = ValueNotifier<String>('');
  final startWithWindows = ValueNotifier<bool>(false);
  /// Android: keep discovery/chat active via foreground service when app is in background.
  final backgroundRunningEnabled = ValueNotifier<bool>(true);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final modeStr = _prefs.getString('theme_mode') ?? 'system';
    themeMode.value = switch (modeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notificationsMuted.value = _prefs.getBool('notifications_muted') ?? false;

    backgroundRunningEnabled.value =
        _prefs.getBool('background_running') ?? true;

    downloadPath.value =
        _prefs.getString('download_path') ?? _defaultDownloadPath();

    if (Platform.isWindows) {
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

  Future<void> setBackgroundRunningEnabled(bool enabled) async {
    backgroundRunningEnabled.value = enabled;
    await _prefs.setBool('background_running', enabled);
  }

  Future<void> setDownloadPath(String path) async {
    downloadPath.value = path;
    await _prefs.setString('download_path', path);
  }

  Future<void> setStartWithWindows(bool enabled) async {
    if (!Platform.isWindows) return;
    startWithWindows.value = enabled;
    final exe = Platform.resolvedExecutable;
    if (enabled) {
      await Process.run('reg', [
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
        '/v', 'LocalChat',
        '/t', 'REG_SZ',
        '/d', exe,
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

  static String _defaultDownloadPath() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) return '$userProfile\\Downloads';
      return Directory.systemTemp.path;
    }
    if (Platform.isAndroid) {
      final appDir = Directory.systemTemp.parent.path;
      return '$appDir/files/LocalChat/Downloads';
    }
    return Directory.systemTemp.path;
  }
}
