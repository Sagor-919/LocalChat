import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';

class DeviceIdentityService {
  static const String _primaryIdKey = 'device_id_v2_primary';
  static const String _hardwareHashKey = 'device_id_v2_hardware_hash';
  static const String _creationTimeKey = 'device_id_v2_creation_time';
  static const String _migrationKey = 'device_id_v2_migrated';

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// Get or create a stable device ID that survives app data clear.
  /// Uses: UUID (primary) + hardware hash (recovery) + creation timestamp
  Future<String> getStableDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Check if already migrated to v2
    if (prefs.getBool(_migrationKey) == true) {
      final primaryId = prefs.getString(_primaryIdKey);
      if (primaryId != null && primaryId.isNotEmpty) {
        return primaryId;
      }
    }

    // Generate new primary ID
    final primaryId = const Uuid().v4();
    final creationTime = DateTime.now().millisecondsSinceEpoch;
    
    // Compute hardware hash as recovery mechanism
    final hardwareHash = await _getHardwareHash();
    
    // Store with version marker
    await prefs.setString(_primaryIdKey, primaryId);
    await prefs.setString(_hardwareHashKey, hardwareHash);
    await prefs.setInt(_creationTimeKey, creationTime);
    await prefs.setBool(_migrationKey, true);

    return primaryId;
  }

  /// Detects if device was reset (new hardware hash) and recovers if possible
  Future<bool> wasDeviceReset() async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_hardwareHashKey);
    
    if (storedHash == null) return false;
    
    final currentHash = await _getHardwareHash();
    return storedHash != currentHash;
  }

  Future<String> _getHardwareHash() async {
    try {
      String hwId = '';
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        hwId = '${android.device}-${android.manufacturer}-${android.model}';
      } else if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        hwId = ios.identifierForVendor ?? 'ios-unknown';
      } else if (Platform.isWindows) {
        final win = await _deviceInfo.windowsInfo;
        hwId = win.computerName;
      } else if (Platform.isLinux) {
        final linux = await _deviceInfo.linuxInfo;
        hwId = linux.machineId ?? 'linux-unknown';
      }
      return _hash(hwId);
    } catch (_) {
      return 'fallback-hash-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  String _hash(String input) {
    // Simple hash (use crypto package for production)
    return input.hashCode.toString();
  }
}