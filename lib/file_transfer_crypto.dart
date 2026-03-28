import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// X25519 + HKDF-SHA256 → 32-byte AES-256 key for file payloads.
Future<Uint8List> deriveFileSessionKeyFromEcdh({
  required SimpleKeyPair localKeyPair,
  required List<int> remotePublicKeyBytes,
}) async {
  final remotePub = SimplePublicKey(
    remotePublicKeyBytes,
    type: KeyPairType.x25519,
  );
  final shared = await X25519().sharedSecretKey(
    keyPair: localKeyPair,
    remotePublicKey: remotePub,
  );
  final hkdf = Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  );
  final derived = await hkdf.deriveKey(
    secretKey: shared,
    nonce: utf8.encode('localchat:file:v1'),
    info: utf8.encode('aes-256-gcm'),
  );
  return Uint8List.fromList(await derived.extractBytes());
}

final _aes = AesGcm.with256bits();

/// Max encrypted frame body (nonce + ciphertext + mac) on the wire.
const int kMaxEncryptedFrameBytes = 70000;

const int kChunkSize = 65536;

/// Encrypt one chunk (≤ kChunkSize plaintext).
///
/// Avoids [Isolate.run] per chunk — spawning an isolate every 64KB caused severe
/// lag on Android; AES-GCM here is async and cheap enough on the IO thread.
Future<Uint8List> encryptFileChunkIsolate(
  Uint8List plaintext,
  Uint8List keyMaterial,
) async {
  final key = SecretKey(keyMaterial);
  final nonce = _aes.newNonce();
  final box = await _aes.encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
  );
  return box.concatenation(nonce: true, mac: true);
}

/// Decrypt one frame from [encryptFileChunkIsolate].
Future<Uint8List> decryptFileChunkIsolate(
  Uint8List frame,
  Uint8List keyMaterial,
) async {
  final key = SecretKey(keyMaterial);
  final box = SecretBox.fromConcatenation(
    frame,
    nonceLength: _aes.nonceLength,
    macLength: _aes.macAlgorithm.macLength,
    copy: false,
  );
  return Uint8List.fromList(await _aes.decrypt(box, secretKey: key));
}

Uint8List frameLengthPrefix(int frameLen) {
  final b = Uint8List(4);
  b[0] = (frameLen >> 24) & 0xff;
  b[1] = (frameLen >> 16) & 0xff;
  b[2] = (frameLen >> 8) & 0xff;
  b[3] = frameLen & 0xff;
  return b;
}

int readU32Be(List<int> bytes, int offset) {
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}
