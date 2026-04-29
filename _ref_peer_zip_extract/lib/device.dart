import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/device_identity_service.dart';

class DeviceInfo {
  final String userId;
  String displayName;

  DeviceInfo({required this.userId, required this.displayName});

  /// Load device info with new identity service.
  /// 
  /// Migration path:
  /// 1. Check if old device_id exists in prefs
  /// 2. Initialize new DeviceIdentityService
  /// 3. Attempt recovery if hardware same
  /// 4. Migrate display name
  /// 
  /// This ensures no duplicate devices after app clear.
  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Step 1: Get old UUID if exists (for migration)
    final oldUuid = prefs.getString('device_id');
    
    // Step 2: Initialize device identity service
    final identityService = DeviceIdentityService();
    final identity = await identityService.initializeDeviceIdentity();
    
    final userId = identity.userId;
    final wasRecovered = identity.wasRecovered;

    // Step 3: Migrate display name from old prefs or generate new
    final saved = prefs.getString('device_name')?.trim();
    String name;
    
    if (saved != null && saved.isNotEmpty && 
        !_isUnsuitableDisplayName(saved)) {
      // Keep existing name
      name = saved;
    } else if (wasRecovered) {
      // Device recovered - keep trying to get old name
      final oldName = prefs.getString('device_name_backup');
      if (oldName != null && oldName.isNotEmpty) {
        name = oldName;
      } else {
        name = _generateDisplayName(userId);
      }
    } else {
      // New device - generate name
      final host = Platform.localHostname.trim();
      if (!_isUnsuitableDisplayName(host)) {
        name = host;
      } else {
        name = _generateDisplayName(userId);
      }
    }

    await prefs.setString('device_name', name);
    
    // Step 4: Backup current UUID in case of future recovery
    await prefs.setString('device_id_backup', userId);

    return DeviceInfo(userId: userId, displayName: name);
  }

  /// Hostnames that are too generic to use as device name.
  static bool _isUnsuitableDisplayName(String raw) {
    if (raw.isEmpty) return true;
    final s = raw.toLowerCase().trim();
    if (s == 'localhost' ||
        s == '127.0.0.1' ||
        s == '::1' ||
        s == 'android' ||
        s == 'unknown' ||
        s == 'null') {
      return true;
    }
    if (s.startsWith('sdk_gphone') || s.startsWith('emulator')) return true;
    return false;
  }

  /// Generate a gaming name from device UUID.
  /// 
  /// Uses seeded random so same UUID always generates same name.
  /// This name changes only when UUID changes (new device).
  static String _generateDisplayName(String userId) {
    final r = Random(userId.hashCode);
    const adjectives = [
      'Swift', 'Neon', 'Shadow', 'Pixel', 'Storm', 'Frost', 'Blaze', 'Volt',
      'Nova', 'Cyber', 'Echo', 'Rogue', 'Silent', 'Iron', 'Quantum', 'Void',
      'Turbo', 'Dark', 'Ice', 'Fire',
    ];
    const nouns = [
      'Fox', 'Wolf', 'Drift', 'Knight', 'Hawk', 'Viper', 'Tiger', 'Phoenix',
      'Raven', 'Strike', 'Ghost', 'Legend', 'Claw', 'Star', 'Pulse', 'Wraith',
      'Fang', 'Bolt', 'Shard', 'Ninja',
    ];
    final a = adjectives[r.nextInt(adjectives.length)];
    final n = nouns[r.nextInt(nouns.length)];
    final tag = 10 + r.nextInt(90);
    return '$a$n$tag';
  }

  /// Update device display name in preferences.
  static Future<void> setName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return; // Don't allow empty names
    await prefs.setString('device_name', trimmed);
  }

  Color get avatarColor {
    const palette = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
    ];
    return palette[userId.hashCode.abs() % palette.length];
  }
}

class PeerDevice {
  final String userId;
  final String name;
  final String ip;
  final int port;
  DateTime lastSeen;

  PeerDevice({
    required this.userId,
    required this.name,
    required this.ip,
    required this.port,
    required this.lastSeen,
  });

  Color get avatarColor {
    const palette = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
    ];
    return palette[userId.hashCode.abs() % palette.length];
  }
}