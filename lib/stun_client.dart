import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'dart:io';

/// Minimal RFC 5389 STUN binding — returns the **server reflexive** IPv4 address
/// observed by the STUN server (typical NAT “WAN” IP for outbound UDP).
class StunBindingResult {
  final InternetAddress publicAddress;
  final int mappedUdpPort;

  const StunBindingResult({
    required this.publicAddress,
    required this.mappedUdpPort,
  });
}

class StunClient {
  StunClient._();

  static const int _magicCookie = 0x2112A442;

  /// Ephemeral UDP socket — external IP is usually the same as for other LAN UDP.
  static Future<StunBindingResult?> queryBinding({
    required String stunHost,
    required int stunPort,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    InternetAddress? serverAddr;
    try {
      serverAddr = InternetAddress(stunHost);
    } catch (_) {
      final r = await InternetAddress.lookup(stunHost);
      if (r.isEmpty) return null;
      serverAddr = r.first;
    }

    final tid = Uint8List(12);
    final rnd = Random.secure();
    for (var i = 0; i < 12; i++) {
      tid[i] = rnd.nextInt(256);
    }

    final req = ByteData(20);
    req.setUint16(0, 0x0001); // Binding Request
    req.setUint16(2, 0);
    req.setUint32(4, _magicCookie);
    final reqBytes = req.buffer.asUint8List();
    reqBytes.setRange(8, 20, tid);

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(reqBytes, serverAddr, stunPort);

      final completer = Completer<StunBindingResult?>();
      late StreamSubscription sub;
      var done = false;

      void finish(StunBindingResult? v) {
        if (done) return;
        done = true;
        sub.cancel();
        if (!completer.isCompleted) completer.complete(v);
      }

      sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final r = _parseBindingResponse(dg.data, tid);
        if (r != null) finish(r);
      });

      Timer(timeout, () => finish(null));

      return await completer.future;
    } catch (_) {
      return null;
    } finally {
      try {
        socket?.close();
      } catch (_) {}
    }
  }

  static StunBindingResult? _parseBindingResponse(Uint8List data, Uint8List tid) {
    if (data.length < 20) return null;
    if (data[0] != 0x01 || data[1] != 0x01) return null; // Success response
    final mlen = (data[2] << 8) | data[3];
    if (data.length < 20 + mlen) return null;
    if (data[4] != 0x21 ||
        data[5] != 0x12 ||
        data[6] != 0xa4 ||
        data[7] != 0x42) {
      return null;
    }
    for (var i = 0; i < 12; i++) {
      if (data[8 + i] != tid[i]) return null;
    }
    var off = 20;
    final end = 20 + mlen;
    while (off + 4 <= end) {
      final atype = (data[off] << 8) | data[off + 1];
      final alen = (data[off + 2] << 8) | data[off + 3];
      off += 4;
      if (off + alen > data.length) break;
      final aval = data.sublist(off, off + alen);
      off += alen;
      final pad = (4 - (alen % 4)) % 4;
      off += pad;

      if (atype == 0x0020 || atype == 0x0001 || atype == 0x0021) {
        final parsed = _parseXorMapped(aval);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static StunBindingResult? _parseXorMapped(Uint8List v) {
    if (v.length < 8) return null;
    final family = v[1];
    if (family != 0x01) return null;
    final xport = ((v[2] << 8) | v[3]) ^ ((_magicCookie >> 16) & 0xffff);
    final ipBytes = Uint8List(4);
    ipBytes[0] = v[4] ^ 0x21;
    ipBytes[1] = v[5] ^ 0x12;
    ipBytes[2] = v[6] ^ 0xa4;
    ipBytes[3] = v[7] ^ 0x42;
    try {
      final addr = InternetAddress.fromRawAddress(ipBytes);
      return StunBindingResult(publicAddress: addr, mappedUdpPort: xport);
    } catch (_) {
      return null;
    }
  }
}
