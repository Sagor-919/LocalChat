import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/device_identity_service.dart';

class DeviceInfo {
  final String userId;
  String displayName;
  /// Opaque LAN tag (from [DeviceIdentityService]); empty if unsupported.
  final String lanStableTag;

  DeviceInfo({
    required this.userId,
    required this.displayName,
    this.lanStableTag = '',
  });

  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }

    final saved = prefs.getString('device_name')?.trim();
    String name;
    if (saved != null && saved.isNotEmpty && !_isUnsuitableDisplayName(saved)) {
      name = saved;
    } else {
      String host = '';
      if (!kIsWeb) {
        try {
          host = Platform.localHostname.trim();
        } catch (_) {}
      }
      if (host.isNotEmpty && !_isUnsuitableDisplayName(host)) {
        name = host;
      } else {
        name = _randomGamingName(id);
      }
      await prefs.setString('device_name', name);
    }

    String tag = '';
    if (!kIsWeb) {
      try {
        tag = await DeviceIdentityService.computeLanStableTag();
      } catch (_) {}
    }
    return DeviceInfo(userId: id, displayName: name, lanStableTag: tag);
  }

  /// Hostnames like `localhost` after reinstall, or generic placeholders.
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

  static String _randomGamingName(String userId) {
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

  static Future<void> setName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', name.trim());
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
  /// From discovery payload; null if legacy peer or wire omitted.
  final String? lanStableTag;

  PeerDevice({
    required this.userId,
    required this.name,
    required this.ip,
    required this.port,
    required this.lastSeen,
    this.lanStableTag,
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
