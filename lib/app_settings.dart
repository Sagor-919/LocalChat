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
  static const _kAutoAcceptIncomingFiles = 'auto_accept_incoming_files';
  static const _kFolderSendAsZip = 'folder_send_as_zip';

  late SharedPreferences _prefs;

  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final notificationsMuted = ValueNotifier<bool>(false);
  final downloadPath = ValueNotifier<String>('');
  final startWithWindows = ValueNotifier<bool>(false);
  /// Desktop: when true, closing the window hides to tray and keeps LAN active; when false, exit the app.
  final desktopRunInBackground = ValueNotifier<bool>(true);
  /// When true, incoming [file_offer] is accepted after a space/write check (any file size).
  final autoAcceptIncomingFiles = ValueNotifier<bool>(true);
  /// Desktop folder sends: true = one .zip (temp file); false = send files with folder layout.
  final folderSendAsZip = ValueNotifier<bool>(true);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final modeStr = _prefs.getString('theme_mode') ?? 'system';
    themeMode.value = switch (modeStr) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notificationsMuted.value = _prefs.getBool('notifications_muted') ?? false;
    autoAcceptIncomingFiles.value =
        _prefs.getBool(_kAutoAcceptIncomingFiles) ?? true;
    folderSendAsZip.value = _prefs.getBool(_kFolderSendAsZip) ?? true;

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      desktopRunInBackground.value =
          _prefs.getBool('desktop_run_in_background') ?? true;
    }

    if (kIsWeb) {
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

  Future<void> setAutoAcceptIncomingFiles(bool enabled) async {
    autoAcceptIncomingFiles.value = enabled;
    await _prefs.setBool(_kAutoAcceptIncomingFiles, enabled);
  }

  Future<void> setFolderSendAsZip(bool asZip) async {
    folderSendAsZip.value = asZip;
    await _prefs.setBool(_kFolderSendAsZip, asZip);
  }

  static bool get supportsDesktopFolderSend =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

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
