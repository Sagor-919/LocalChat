import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'device.dart';

class DiscoveryService {
  static const int udpPort = 4040;
  static const int tcpPort = 4041;
  static const Duration broadcastInterval = Duration(seconds: 2);
  static const Duration staleTimeout = Duration(seconds: 6);
  /// Link-local admin multicast; works on many networks when 255.255.255.255 is filtered.
  static const String _multicastGroup = '239.255.76.76';

  static const MethodChannel _androidDiscovery =
      MethodChannel('local_chat/discovery');

  final DeviceInfo me;
  final Map<String, PeerDevice> _peers = {};
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _broadcastTargetsTimer;
  List<InternetAddress> _cachedBroadcastTargets = [];
  void Function()? onPeersChanged;

  DiscoveryService({required this.me});

  List<PeerDevice> get peers => _peers.values.toList();

  Future<void> start() async {
    if (Platform.isAndroid) {
      try {
        await _androidDiscovery.invokeMethod<void>('acquireMulticastLock');
      } catch (_) {}
    }

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

    _joinMulticastGroups();

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _socket!.receive();
      if (dg == null) return;

      try {
        final msg = utf8.decode(dg.data);
        _handleMessage(msg, dg.address.address);
      } catch (_) {}
    });

    unawaited(_refreshBroadcastTargets());
    _broadcastTargetsTimer =
        Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshBroadcastTargets());
    });

    _broadcastTimer = Timer.periodic(broadcastInterval, (_) => _broadcast());
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _removeStale());
    _broadcast();
  }

  void _joinMulticastGroups() {
    final s = _socket;
    if (s == null) return;
    final group = InternetAddress(_multicastGroup);
    try {
      s.joinMulticast(group);
    } catch (_) {}
    if (kIsWeb) return;
    try {
      NetworkInterface.list(includeLinkLocal: false).then((ifaces) {
        for (final iface in ifaces) {
          for (final addr in iface.addresses) {
            if (addr.type != InternetAddressType.IPv4) continue;
            if (addr.isLoopback) continue;
            try {
              s.joinMulticast(group, iface);
            } catch (_) {}
          }
        }
      });
    } catch (_) {}
  }

  /// Subnet broadcast(s) for Wi‑Fi/LAN; global broadcast is unreliable on many Androids.
  Future<void> _refreshBroadcastTargets() async {
    if (kIsWeb) return;
    final seen = <String>{};
    final out = <InternetAddress>[];

    void addAddr(String host) {
      if (seen.contains(host)) return;
      seen.add(host);
      try {
        out.add(InternetAddress(host));
      } catch (_) {}
    }

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final b = await NetworkInfo().getWifiBroadcast();
        if (b != null && b.isNotEmpty) addAddr(b);
      } catch (_) {}
    }

    try {
      for (final iface in await NetworkInterface.list(includeLinkLocal: false)) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          if (addr.isLoopback) continue;
          final b24 = _ipv4Broadcast24(addr);
          if (b24 != null) addAddr(b24);
        }
      }
    } catch (_) {}

    _cachedBroadcastTargets = out;
  }

  static String? _ipv4Broadcast24(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return null;
    final r = addr.rawAddress;
    if (r.length != 4) return null;
    return '${r[0]}.${r[1]}.${r[2]}.255';
  }

  void _broadcast() {
    final msg = 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort';
    final data = utf8.encode(msg);
    try {
      _socket?.send(data, InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {}
    try {
      _socket?.send(data, InternetAddress(_multicastGroup), udpPort);
    } catch (_) {}
    for (final target in _cachedBroadcastTargets) {
      try {
        _socket?.send(data, target, udpPort);
      } catch (_) {}
    }
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
    _broadcastTargetsTimer?.cancel();
    _broadcastTargetsTimer = null;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
    if (Platform.isAndroid) {
      try {
        _androidDiscovery.invokeMethod<void>('releaseMulticastLock');
      } catch (_) {}
    }
  }
}
