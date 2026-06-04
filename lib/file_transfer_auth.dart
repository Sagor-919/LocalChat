import 'dart:convert';

import 'package:crypto/crypto.dart';

/// HMAC-less keyed digest for file TCP auth — derived from the same peer-pair
/// material as [ChatCrypto], scoped per [fileId].
class FileTransferAuth {
  FileTransferAuth._();

  static const _prefix = 'localchat:file:v1:';

  static String token(String localId, String remotePeerId, String fileId) {
    final ids = [localId, remotePeerId]..sort();
    final raw = utf8.encode('$_prefix${ids[0]}:${ids[1]}:$fileId');
    return sha256.convert(raw).toString();
  }

  static bool verify(
    String localId,
    String remotePeerId,
    String fileId,
    String? provided,
  ) {
    if (provided == null || provided.isEmpty) return false;
    final expected = token(localId, remotePeerId, fileId);
    return _constantTimeEquals(
      expected.toLowerCase(),
      provided.trim().toLowerCase(),
    );
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
