import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

class DiscoveryService {
  static const int udpPort = 4040;
  static const int tcpPort = 4041;
  static const Duration broadcastInterval = Duration(seconds: 2);
  static const Duration staleTimeout = Duration(seconds: 6);

  final DeviceInfo me;
  final Map<String, PeerDevice> _peers = {};
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  void Function()? onPeersChanged;

  DiscoveryService({required this.me});

  List<PeerDevice> get peers => _peers.values.toList();

  Future<void> start() async {
    // reusePort is unsupported on Android; reuseAddress:true has caused
    // reusePort-related failures on some Android builds — keep both off there.
    final reuseAddr = !Platform.isAndroid;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpPort,
      reuseAddress: reuseAddr,
      reusePort: false,
    );
    _socket!.broadcastEnabled = true;

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;

      try {
        final msg = utf8.decode(dg.data);
        _handleMessage(msg, dg.address.address);
      } catch (_) {}
    });

    _broadcastTimer = Timer.periodic(broadcastInterval, (_) => _broadcast());
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _removeStale());
    _broadcast();
  }

  void _broadcast() {
    final msg = 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort';
    final data = utf8.encode(msg);
    try {
      _socket?.send(data, InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {}
  }

  void _handleMessage(String raw, String senderIp) {
    if (!raw.startsWith('LOCALCHAT|')) return;
    final parts = raw.split('|');
    if (parts.length < 4) return;

    final userId = parts[1];
    final name = parts[2];
    final port = int.tryParse(parts[3]) ?? tcpPort;

    if (userId == me.userId) return;

    final existing = _peers[userId];
    if (existing != null) {
      existing.lastSeen = DateTime.now();
      if (existing.name != name ||
          existing.ip != senderIp ||
          existing.port != port) {
        _peers[userId] = PeerDevice(
          userId: userId,
          name: name,
          ip: senderIp,
          port: port,
          lastSeen: DateTime.now(),
        );
      }
    } else {
      _peers[userId] = PeerDevice(
        userId: userId,
        name: name,
        ip: senderIp,
        port: port,
        lastSeen: DateTime.now(),
      );
    }
    onPeersChanged?.call();
  }

  void _removeStale() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere(
        (_, p) => now.difference(p.lastSeen) > staleTimeout);
    if (_peers.length != before) onPeersChanged?.call();
  }

  void stop() {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
  }
}
