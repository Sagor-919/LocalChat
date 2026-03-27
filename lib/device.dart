import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceInfo {
  final String userId;
  String displayName;

  DeviceInfo({required this.userId, required this.displayName});

  static Future<DeviceInfo> load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    final name = prefs.getString('device_name') ?? Platform.localHostname;
    return DeviceInfo(userId: id, displayName: name);
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
