import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// HMAC for UDP discovery payloads (QA item 20).
class DiscoverySigning {
  DiscoverySigning._();

  static const _kSecret = 'discovery_hmac_secret_v1';

  static Future<String> ensureSecret(SharedPreferences prefs) async {
    var s = prefs.getString(_kSecret);
    if (s == null || s.isEmpty) {
      s = List.generate(
        32,
        (i) => (DateTime.now().microsecondsSinceEpoch + i).toRadixString(16),
      ).join();
      await prefs.setString(_kSecret, s);
    }
    return s;
  }

  static String signPayload(String payload, String secret) {
    final mac = Hmac(sha256, utf8.encode(secret));
    return mac.convert(utf8.encode(payload)).toString();
  }

  static bool verifyPayload(String payload, String sigHex, String secret) {
    if (sigHex.isEmpty) return false;
    final expected = signPayload(payload, secret);
    if (expected.length != sigHex.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ sigHex.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// `LOCALCHAT|...|platform|sig`
  static String appendSignature(String unsigned, String secret) {
    final sig = signPayload(unsigned, secret);
    return '$unsigned|$sig';
  }

  static ({String payload, String? sig}) splitSignedLine(String line) {
    final parts = line.split('|');
    if (parts.length < 7) return (payload: line, sig: null);
    final sig = parts.removeLast();
    return (payload: parts.join('|'), sig: sig);
  }
}
