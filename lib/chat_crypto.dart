import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

/// LAN-style confidentiality: AES-256-GCM with a key derived from the two
/// peer IDs (sorted). Same model as session material in `_ref_lanmessenger`
/// (per-peer AES), without RSA handshake — suitable for trusted LANs only.
class ChatCrypto {
  ChatCrypto._();

  static final _algo = AesGcm.with256bits();

  static Future<SecretKey> _secretKey(String a, String b) async {
    final ids = [a, b]..sort();
    final raw = utf8.encode('localchat:v1:${ids[0]}:${ids[1]}');
    final h = await Sha256().hash(raw);
    return SecretKey(h.bytes);
  }

  /// Plain inner JSON: `{"text":"...","sha":"<hex of utf8 text>"}` then AES-GCM.
  static Future<String?> encryptMessage(
    String myId,
    String peerId,
    String text,
  ) async {
    final shaHex = sha256.convert(utf8.encode(text)).toString();
    final inner = jsonEncode({'text': text, 'sha': shaHex});
    final key = await _secretKey(myId, peerId);
    final box = await _algo.encrypt(
      utf8.encode(inner),
      secretKey: key,
    );
    return base64Encode(box.concatenation());
  }

  /// Returns decrypted text, or null if MAC fails or checksum mismatch.
  static Future<String?> decryptMessage(
    String myId,
    String peerId,
    String b64,
  ) async {
    try {
      final raw = base64Decode(b64);
      final key = await _secretKey(myId, peerId);
      final box = SecretBox.fromConcatenation(
        raw,
        nonceLength: 12,
        macLength: 16,
      );
      final clear = await _algo.decrypt(box, secretKey: key);
      final inner =
          jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final text = inner['text'] as String? ?? '';
      final expect = inner['sha'] as String? ?? '';
      final actual = sha256.convert(utf8.encode(text)).toString();
      if (expect != actual) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  static String checksumUtf8Text(String text) =>
      sha256.convert(utf8.encode(text)).toString();
}
