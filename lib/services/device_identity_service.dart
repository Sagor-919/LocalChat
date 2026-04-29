import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// LAN-visible stable tag derived from OS-level identifiers (not the prefs UUID).
///
/// Used only for **peer-side deduplication**: when a neighbor clears app data they get a
/// new [DeviceInfo.userId], but the same [computeLanStableTag] lets us merge threads.
///
/// This is a **non-secret opaque tag**; do not use it for authentication.
class DeviceIdentityService {
  DeviceIdentityService._();

  /// 16-char hex prefix of SHA-256; empty if unavailable.
  static Future<String> computeLanStableTag() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        final raw = a.id.trim();
        if (raw.isEmpty) return '';
        return _shortHash(raw);
      }
      if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        final v = i.identifierForVendor?.trim();
        if (v == null || v.isEmpty) return '';
        return _shortHash(v);
      }
      if (Platform.isWindows) {
        final w = await plugin.windowsInfo;
        final blob = [
          w.computerName,
          w.userName,
          w.deviceId,
          w.productId,
        ].where((s) => s.trim().isNotEmpty).join('|');
        if (blob.isEmpty) return '';
        return _shortHash(blob);
      }
      if (Platform.isLinux) {
        final l = await plugin.linuxInfo;
        final raw = '${l.machineId ?? ''}|${l.prettyName}'.trim();
        if (raw.isEmpty) return '';
        return _shortHash(raw);
      }
      if (Platform.isMacOS) {
        final m = await plugin.macOsInfo;
        final raw =
            '${m.hostName}|${m.computerName}|${m.systemGUID ?? ''}'.trim();
        if (raw.isEmpty) return '';
        return _shortHash(raw);
      }
    } catch (e, st) {
      debugPrint('DeviceIdentityService.computeLanStableTag: $e\n$st');
    }
    return '';
  }

  static String _shortHash(String input) {
    final bytes = sha256.convert(utf8.encode(input));
    return bytes.toString().substring(0, 16);
  }
}
