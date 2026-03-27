import 'package:shared_preferences/shared_preferences.dart';

class SettingsStorage {
  static const _keyDownloadDir = 'drivechat_download_dir';
  static const _keyNotificationsEnabled = 'drivechat_notifications_enabled';

  final SharedPreferences _prefs;
  SettingsStorage(this._prefs);

  static Future<SettingsStorage> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStorage(prefs);
  }

  String? get downloadDir => _prefs.getString(_keyDownloadDir);
  Future<void> setDownloadDir(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_keyDownloadDir);
    } else {
      await _prefs.setString(_keyDownloadDir, path);
    }
  }

  bool get notificationsEnabled =>
      _prefs.getBool(_keyNotificationsEnabled) ?? true;
  Future<void> setNotificationsEnabled(bool enabled) async {
    await _prefs.setBool(_keyNotificationsEnabled, enabled);
  }
}

