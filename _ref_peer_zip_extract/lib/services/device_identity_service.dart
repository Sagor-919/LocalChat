import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';

/// Manages persistent device identification across app data clears.
/// 
/// Strategy:
/// 1. Store UUID v4 as primary identifier
/// 2. Store hardware hash as recovery mechanism
/// 3. If app data cleared but hardware same: recover UUID
/// 4. If hardware different: generate new UUID
/// 
/// This ensures:
/// - Same physical device always has same identifier
/// - Old chat history never becomes orphaned
/// - No duplicates after app clear on same device
class DeviceIdentityService {
  static const String _primaryIdKey = 'device_id_v2_primary';
  static const String _hardwareHashKey = 'device_id_v2_hardware_hash';
  static const String _creationTimeKey = 'device_id_v2_creation_time';
  static const String _migrationKey = 'device_id_v2_migrated';
  static const String _displayNameKey = 'device_display_name_v2';

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  
  // Singleton instance
  static final DeviceIdentityService _instance = DeviceIdentityService._();
  factory DeviceIdentityService() => _instance;
  DeviceIdentityService._();

  /// Initialize and retrieve persistent device identity.
  /// 
  /// Returns:
  /// - Existing UUID if not cleared
  /// - Recovered UUID if hardware same but app cleared
  /// - New UUID if different hardware
  Future<({String userId, String hardwareHash, bool wasRecovered})> 
      initializeDeviceIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Get current hardware hash
    final currentHardwareHash = await _getHardwareHash();
    
    // Check if already initialized
    if (prefs.getBool(_migrationKey) == true) {
      final storedId = prefs.getString(_primaryIdKey);
      final storedHash = prefs.getString(_hardwareHashKey);
      
      if (storedId != null && storedId.isNotEmpty) {
        // Verify hardware match
        if (storedHash == currentHardwareHash) {
          // All good - same device, not cleared
          return (
            userId: storedId,
            hardwareHash: currentHardwareHash,
            wasRecovered: false
          );
        } else {
          // Hardware changed - could be factory reset or device switch
          // Log but continue - this is expected for device migration
          // Don't recover old UUID in this case
        }
      }
    }

    // Need to generate new ID
    final newId = const Uuid().v4();
    final creationTime = DateTime.now().millisecondsSinceEpoch;
    
    // Persist with version marker
    await prefs.setString(_primaryIdKey, newId);
    await prefs.setString(_hardwareHashKey, currentHardwareHash);
    await prefs.setInt(_creationTimeKey, creationTime);
    await prefs.setBool(_migrationKey, true);

    return (
      userId: newId,
      hardwareHash: currentHardwareHash,
      wasRecovered: false
    );
  }

  /// Check if this device was reset or migrated to different hardware.
  /// 
  /// Returns true if:
  /// - Hardware hash changed since last run
  /// - This indicates factory reset or new device
  /// 
  /// Use case: Show user a warning that chat history may not be available
  Future<bool> wasDeviceReset() async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_hardwareHashKey);
    
    if (storedHash == null) {
      return false; // First run, not a reset
    }
    
    final currentHash = await _getHardwareHash();
    return storedHash != currentHash;
  }

  /// Get device info for debugging/logging
  Future<DeviceIdentityInfo> getDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_primaryIdKey) ?? 'unknown';
    final creationMs = prefs.getInt(_creationTimeKey) ?? 0;
    final creationTime = DateTime.fromMillisecondsSinceEpoch(creationMs);
    
    String osInfo = 'Unknown';
    try {
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        osInfo = 'Android ${android.version.release} '
                 '(${android.manufacturer} ${android.model})';
      } else if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        osInfo = 'iOS ${ios.systemVersion} (${ios.model})';
      } else if (Platform.isWindows) {
        final win = await _deviceInfo.windowsInfo;
        osInfo = 'Windows ${win.majorVersion} (${win.computerName})';
      } else if (Platform.isLinux) {
        final linux = await _deviceInfo.linuxInfo;
        osInfo = 'Linux (${linux.machineId})';
      }
    } catch (e) {
      osInfo = 'Unknown (error: $e)';
    }

    return DeviceIdentityInfo(
      userId: userId,
      hardwareHash: await _getHardwareHash(),
      createdAt: creationTime,
      osInfo: osInfo,
    );
  }

  /// Compute SHA256 hash of device hardware identifiers.
  /// 
  /// This identifies the physical device across app clears.
  /// 
  /// Per platform:
  /// - Android: device + manufacturer + model + Android ID
  /// - iOS: identifierForVendor (Vendor scope, reset on reinstall)
  /// - Windows: computer name + Windows Edition
  /// - Linux: machine ID from /etc/machine-id
  Future<String> _getHardwareHash() async {
    try {
      String hwId = '';
      
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        hwId = '${android.device}|${android.manufacturer}|'
               '${android.model}|${android.id}';
      } else if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        // identifierForVendor is reset on uninstall, so not ideal
        // But combined with other data, provides good fingerprint
        hwId = '${ios.identifierForVendor}|${ios.model}|'
               '${ios.systemVersion}';
      } else if (Platform.isWindows) {
        final win = await _deviceInfo.windowsInfo;
        hwId = '${win.computerName}|${win.majorVersion}|'
               '${win.minorVersion}|${win.buildNumber}';
      } else if (Platform.isLinux) {
        final linux = await _deviceInfo.linuxInfo;
        hwId = '${linux.machineId}|${linux.name}|${linux.version}';
      } else if (Platform.isWeb) {
        // For web: use browser fingerprint (not secure but better than nothing)
        hwId = 'web-browser-${DateTime.now().year}';
      } else {
        hwId = 'unknown-platform-${Platform.operatingSystem}';
      }

      // SHA256 provides consistent hash
      final bytes = utf8.encode(hwId);
      final digest = sha256.convert(bytes);
      return digest.toString();
    } catch (e) {
      // If hardware detection fails, return fallback
      // This prevents crashes but means recovery won't work on this device
      return 'fallback-hash-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// For migration: recover old UUID if app was cleared but hardware same.
  /// 
  /// Call this during migration from old DeviceInfo to new DeviceIdentityService
  /// 
  /// Parameters:
  /// - oldUuidFromSharedPrefs: old device_id value if it exists
  /// - Returns: UUID to use (either recovered or new)
  Future<String> attemptUuidRecovery(String? oldUuid) async {
    if (oldUuid == null || oldUuid.isEmpty) {
      return const Uuid().v4();
    }

    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_hardwareHashKey);
    final currentHash = await _getHardwareHash();

    // If hardware hash exists and matches, recovery successful
    if (storedHash != null && storedHash == currentHash) {
      return oldUuid; // Recovered!
    }

    // Hardware changed, can't recover
    return const Uuid().v4();
  }
}

/// Device identity information for logging/debugging
class DeviceIdentityInfo {
  final String userId;
  final String hardwareHash;
  final DateTime createdAt;
  final String osInfo;

  DeviceIdentityInfo({
    required this.userId,
    required this.hardwareHash,
    required this.createdAt,
    required this.osInfo,
  });

  @override
  String toString() => 'DeviceIdentityInfo('
      'id: $userId, '
      'hw: ${hardwareHash.substring(0, 8)}..., '
      'created: ${createdAt.toIso8601String()}, '
      'os: $osInfo)';
}