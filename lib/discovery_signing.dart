import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC for UDP discovery payloads (QA item 20).
///
/// Uses a protocol-wide key so every peer can verify every other peer's beacon
/// (per-device secrets broke discovery between updated builds).
class DiscoverySigning {
  DiscoverySigning._();

  /// Shared LAN discovery integrity key (not a peer identity secret).
  static String get protocolHmacKey =>
      sha256.convert(utf8.encode('localchat:discovery:v1')).toString();

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
  static String appendSignature(String unsigned, [String? secret]) {
    final key = secret ?? protocolHmacKey;
    final sig = signPayload(unsigned, key);
    return '$unsigned|$sig';
  }

  static ({String payload, String? sig}) splitSignedLine(String line) {
    final parts = line.split('|');
    if (parts.length < 7) return (payload: line, sig: null);
    final sig = parts.removeLast();
    return (payload: parts.join('|'), sig: sig);
  }
}
