import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM per-chunk encryption for file TCP (QA item 8).
class FileTransferCrypto {
  FileTransferCrypto._();

  static final _algo = AesGcm.with256bits();

  static Future<SecretKey> secretKey(
    String peerA,
    String peerB,
    String fileId,
  ) async {
    final ids = [peerA, peerB]..sort();
    final raw = utf8.encode(
      'localchat:file:enc:v1:${ids[0]}:${ids[1]}:$fileId',
    );
    final h = await Sha256().hash(raw);
    return SecretKey(h.bytes);
  }

  static List<int> _nonce(int sequence) {
    final n = Uint8List(12);
    final bd = ByteData.sublistView(n);
    // Encode the full 64-bit sequence (high/low) so the nonce never wraps
    // within any addressable file size — a 32-bit-only counter would reuse a
    // (key, nonce) pair for very large streams, which is fatal for GCM.
    bd.setUint32(4, (sequence >> 32) & 0xFFFFFFFF);
    bd.setUint32(8, sequence & 0xFFFFFFFF);
    return n;
  }

  static Future<Uint8List> encryptChunk(
    SecretKey key,
    int sequence,
    List<int> plain,
  ) async {
    final box = await _algo.encrypt(
      plain,
      secretKey: key,
      nonce: _nonce(sequence),
    );
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List> decryptChunk(
    SecretKey key,
    int sequence,
    List<int> cipher,
  ) async {
    final box = SecretBox.fromConcatenation(
      cipher,
      nonceLength: 12,
      macLength: 16,
    );
    final clear = await _algo.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  }

  static Uint8List lengthPrefix(Uint8List payload) {
    final out = Uint8List(4 + payload.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, payload.length);
    out.setRange(4, out.length, payload);
    return out;
  }
}
