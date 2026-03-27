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

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final modeStr = _prefs.getString('theme_mode') ?? 'system';
    themeMode.value = switch (modeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notificationsMuted.value = _prefs.getBool('notifications_muted') ?? false;

    downloadPath.value =
        _prefs.getString('download_path') ?? _defaultDownloadPath();
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

  Future<void> setDownloadPath(String path) async {
    downloadPath.value = path;
    await _prefs.setString('download_path', path);
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
