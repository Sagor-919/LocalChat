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
  StreamSubscription<RawSocketEvent>? _socketSub;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _broadcastTargetsTimer;
  List<InternetAddress> _cachedBroadcastTargets = [];
  bool _hasVirtualLanInterface = false;
  bool _hasPhysicalLanInterface = false;
  void Function()? onPeersChanged;

  /// When non-null, peers for which this returns true are **not** pruned for
  /// UDP silence — avoids dropping from the list while chat TCP is still up.
  bool Function(String peerId)? hasActiveChatTcp;

  /// True after [start] completes; used to guard [rebindUdpSocket].
  bool _started = false;

  DiscoveryService({required this.me});

  List<PeerDevice> get peers => _peers.values.toList();

  /// UDP bound and discovery loop running — best-effort signal that we can advertise.
  bool get isAdvertisingActive => _started && _socket != null;

  /// Hyper‑V / WSL / Docker virtual NICs plus a real LAN NIC — common cause of
  /// one-way discovery when PC is wired and phone is on Wi‑Fi.
  bool get showsMixedNetworkHint =>
      _hasVirtualLanInterface && _hasPhysicalLanInterface;

  /// True when interface name looks like a host-only virtual switch (Hyper‑V,
  /// WSL, Docker, VPN, etc.) — not the LAN where phones live.
  @visibleForTesting
  static bool isVirtualLanInterfaceName(String name) {
    final n = name.toLowerCase();
    return n.contains('vethernet') ||
        n.contains('hyper-v') ||
        n.contains('wsl') ||
        n.contains('docker') ||
        n.contains('virtualbox') ||
        n.contains('vmware') ||
        n.contains('vpn') ||
        n.contains('tap') ||
        n.contains('tun') ||
        n.contains('loopback');
  }

  /// IPv4 suitable for LAN discovery beacons (not loopback / link-local).
  @visibleForTesting
  static bool isLanRoutableIpv4(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return false;
    final r = addr.rawAddress;
    if (r.length != 4) return false;
    // APIPA
    if (r[0] == 169 && r[1] == 254) return false;
    return true;
  }

  Future<void> start() async {
    if (Platform.isAndroid) {
      try {
        await _androidDiscovery.invokeMethod<void>('acquireMulticastLock');
      } catch (_) {}
    }

    try {
      await _bindUdpSocket();
    } catch (e) {
      if (Platform.isAndroid) {
        try {
          _androidDiscovery.invokeMethod<void>('releaseMulticastLock');
        } catch (_) {}
      }
      rethrow;
    }
    _attachDatagramListener();

    // Subnet broadcast targets must be ready before the first beacon — many
    // Android devices ignore 255.255.255.255 but accept 192.168.x.255.
    await _refreshBroadcastTargets();
    _broadcastTargetsTimer =
        Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshBroadcastTargets());
    });

    _broadcastTimer = Timer.periodic(broadcastInterval, (_) => _broadcast());
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _removeStale());
    _broadcast();
    _started = true;
  }

  Future<void> _bindUdpSocket() async {
    final reuseAddr = !Platform.isAndroid;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      udpPort,
      reuseAddress: reuseAddr,
      reusePort: false,
    );
    _socket!.broadcastEnabled = true;
    _joinMulticastGroups();
  }

  void _attachDatagramListener() {
    final s = _socket;
    if (s == null) return;
    _socketSub?.cancel();
    _socketSub = s.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = s.receive();
      if (dg == null) return;

      try {
        final msg = utf8.decode(dg.data);
        _handleMessage(msg, dg.address.address);
      } catch (_) {}
    });
  }

  /// Register a peer learned from an active TCP session (chat or file). Keeps
  /// the home list in sync when UDP broadcast is blocked (e.g. Ethernet PC →
  /// Wi‑Fi phone) and enables directed unicast discovery beacons to that IP.
  void rememberPeerFromTcp({
    required String userId,
    required String name,
    required String ip,
    int port = tcpPort,
    String? lanStableTag,
  }) {
    if (userId == me.userId) return;
    final trimmedIp = ip.trim();
    if (trimmedIp.isEmpty) return;
    _upsertPeer(
      userId: userId,
      name: name,
      ip: trimmedIp,
      port: port,
      lanStableTag: lanStableTag,
    );
  }

  /// After Wi‑Fi/VPN changes, the old [RawDatagramSocket] may stop receiving
  /// multicast/broadcast until the process restarts — same as “restart app fixes it”.
  /// Close and rebind so discovery works again without killing the process.
  Future<void> rebindUdpSocket() async {
    if (!_started) return;
    _socketSub?.cancel();
    _socketSub = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;

    if (Platform.isAndroid) {
      try {
        await _androidDiscovery.invokeMethod<void>('acquireMulticastLock');
      } catch (_) {}
    }

    await _bindUdpSocket();
    _attachDatagramListener();
    await _refreshBroadcastTargets();
    _joinMulticastGroups();
    _broadcast();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _broadcast();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _broadcast();
  }

  /// Joins multicast on the default socket and per physical IPv4 interface.
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
          if (isVirtualLanInterfaceName(iface.name)) continue;
          for (final addr in iface.addresses) {
            if (!isLanRoutableIpv4(addr)) continue;
            try {
              s.joinMulticast(group, iface);
            } catch (_) {}
          }
        }
      });
    } catch (_) {}
  }

  /// App resumed — refresh targets and rebind UDP so receive path works again.
  Future<void> recoverAfterNetworkOrResume() async {
    await rebindUdpSocket();
  }

  /// Subnet broadcast(s) for Wi‑Fi/LAN; skips Hyper‑V/WSL virtual NICs.
  Future<void> _refreshBroadcastTargets() async {
    if (kIsWeb) return;
    final seen = <String>{};
    final out = <InternetAddress>[];
    var sawVirtual = false;
    var sawPhysical = false;

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
        final virtual = isVirtualLanInterfaceName(iface.name);
        if (virtual) {
          sawVirtual = true;
          continue;
        }
        for (final addr in iface.addresses) {
          if (!isLanRoutableIpv4(addr)) continue;
          sawPhysical = true;
          final b24 = _ipv4Broadcast24(addr);
          if (b24 != null) addAddr(b24);
        }
      }
    } catch (_) {}

    _cachedBroadcastTargets = out;
    _hasVirtualLanInterface = sawVirtual;
    _hasPhysicalLanInterface = sawPhysical;
  }

  static String? _ipv4Broadcast24(InternetAddress addr) {
    if (!isLanRoutableIpv4(addr)) return null;
    final r = addr.rawAddress;
    return '${r[0]}.${r[1]}.${r[2]}.255';
  }

  void _broadcast() {
    final tag = me.lanStableTag.trim();
    final msg = tag.isEmpty
        ? 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort'
        : 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort|$tag';
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
    // Directed unicast: works when router blocks wired→Wi‑Fi broadcast.
    final unicastIps = <String>{};
    for (final peer in _peers.values) {
      final ip = peer.ip.trim();
      if (ip.isEmpty || unicastIps.contains(ip)) continue;
      final addr = InternetAddress.tryParse(ip);
      if (addr == null || !isLanRoutableIpv4(addr)) continue;
      unicastIps.add(ip);
      try {
        _socket?.send(data, addr, udpPort);
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
    String? wireTag;
    if (parts.length >= 5) {
      final tagRaw = parts[4].trim();
      if (tagRaw.isNotEmpty && tagRaw != '-') wireTag = tagRaw;
    }

    if (userId == me.userId) return;

    _upsertPeer(
      userId: userId,
      name: name,
      ip: senderIp,
      port: port,
      lanStableTag: wireTag,
    );
  }

  void _upsertPeer({
    required String userId,
    required String name,
    required String ip,
    required int port,
    String? lanStableTag,
  }) {
    final existing = _peers[userId];
    final effectiveTag = lanStableTag ?? existing?.lanStableTag;
    final now = DateTime.now();

    if (existing != null) {
      final same = existing.name == name &&
          existing.ip == ip &&
          existing.port == port &&
          existing.lanStableTag == effectiveTag;
      existing.lastSeen = now;
      if (!same) {
        _peers[userId] = PeerDevice(
          userId: userId,
          name: name,
          ip: ip,
          port: port,
          lastSeen: now,
          lanStableTag: effectiveTag,
        );
        onPeersChanged?.call();
      }
      return;
    }

    _peers[userId] = PeerDevice(
      userId: userId,
      name: name,
      ip: ip,
      port: port,
      lastSeen: now,
      lanStableTag: effectiveTag,
    );
    onPeersChanged?.call();
  }

  void _removeStale() {
    final now = DateTime.now();
    final before = _peers.length;
    _peers.removeWhere((id, p) {
      if (hasActiveChatTcp?.call(id) == true) return false;
      return now.difference(p.lastSeen) > staleTimeout;
    });
    if (_peers.length != before) {
      onPeersChanged?.call();
    }
  }

  void stop() {
    _started = false;
    _broadcastTargetsTimer?.cancel();
    _broadcastTargetsTimer = null;
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    if (Platform.isAndroid) {
      try {
        _androidDiscovery.invokeMethod<void>('releaseMulticastLock');
      } catch (_) {}
    }
  }
}
