import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'app_settings.dart';
import 'device.dart';
import 'network_adapter_service.dart';

/// Empty-state search progression for the home screen:
/// passive listen → active subnet sweep → exhausted (offer "Add by IP").
enum DiscoverySearchPhase { searching, scanning, exhausted }

class DiscoveryService {
  static const int udpPort = 4040;
  static const int tcpPort = 4041;
  static const Duration broadcastInterval = Duration(seconds: 2);
  static const Duration staleTimeout = Duration(seconds: 6);

  /// Delay after start with no peers before the active unicast sweep begins.
  static const Duration sweepDelay = Duration(seconds: 5);

  /// Sweep throttle: at most [_sweepHostsPerTick] datagrams every [_sweepTick]
  /// (~20 IPs/sec) so a /24 finishes in ~13s without flooding the NIC.
  static const Duration _sweepTick = Duration(milliseconds: 250);
  static const int _sweepHostsPerTick = 5;

  /// Link-local admin multicast; works on many networks when 255.255.255.255 is filtered.
  static const String _multicastGroup = '239.255.76.76';

  static const MethodChannel _androidDiscovery =
      MethodChannel('local_chat/discovery');

  final DeviceInfo me;
  final NetworkAdapterService _adapters = const NetworkAdapterService();
  final Map<String, PeerDevice> _peers = {};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _broadcastTargetsTimer;
  Timer? _sweepDelayTimer;
  Timer? _sweepTimer;
  List<InternetAddress> _cachedBroadcastTargets = [];
  List<LanAdapter> _activeAdapters = [];
  List<InternetAddress> _sweepQueue = [];
  int _sweepIndex = 0;
  bool _hasVirtualLanInterface = false;
  bool _hasPhysicalLanInterface = false;
  void Function()? onPeersChanged;

  /// Empty-state phase for the home screen. UI listens to drive its messaging.
  final ValueNotifier<DiscoverySearchPhase> searchPhase =
      ValueNotifier<DiscoverySearchPhase>(DiscoverySearchPhase.searching);

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

  /// Back-compat shim — see [NetworkAdapterService.isVirtualInterfaceName].
  @visibleForTesting
  static bool isVirtualLanInterfaceName(String name) =>
      NetworkAdapterService.isVirtualInterfaceName(name);

  /// Back-compat shim — see [NetworkAdapterService.isLanRoutableIpv4].
  @visibleForTesting
  static bool isLanRoutableIpv4(InternetAddress addr) =>
      NetworkAdapterService.isLanRoutableIpv4(addr);

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
    _scheduleSweep();
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

  /// Send a directed discovery beacon to a single host. Used by the active
  /// sweep, startup unicast to stored peers, and the manual "Add by IP" flow.
  void unicastBeaconTo(String ip) {
    final addr = InternetAddress.tryParse(ip.trim());
    if (addr == null || !NetworkAdapterService.isLanRoutableIpv4(addr)) return;
    try {
      _socket?.send(_beaconBytes(), addr, udpPort);
    } catch (_) {}
  }

  /// Fire directed beacons at known peer IPs from history so a peer that is
  /// online but unreachable by broadcast (router AP isolation) appears fast
  /// without first exchanging a TCP message.
  void pingStoredPeers(Iterable<String> ips) {
    for (final ip in ips) {
      unicastBeaconTo(ip);
    }
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
    if (_peers.isEmpty) _scheduleSweep();
  }

  /// Joins multicast on the default socket and per active LAN interface, so the
  /// receive path is bound to the real LAN NIC (not a Hyper‑V/WSL switch) and
  /// honors any manual adapter override.
  void _joinMulticastGroups() {
    final s = _socket;
    if (s == null) return;
    final group = InternetAddress(_multicastGroup);
    try {
      s.joinMulticast(group);
    } catch (_) {}
    if (kIsWeb) return;
    final pref = AppSettings.instance.preferredAdapterName.value.trim();
    unawaited(() async {
      try {
        final ifaces = await NetworkInterface.list(
          includeLinkLocal: false,
          type: InternetAddressType.IPv4,
        );
        for (final iface in ifaces) {
          if (!_interfaceSelected(iface, pref)) continue;
          try {
            s.joinMulticast(group, iface);
          } catch (_) {}
        }
      } catch (_) {}
    }());
  }

  /// Mirrors [NetworkAdapterService.selectActive] for a live [NetworkInterface]:
  /// a manual override wins by name; otherwise the interface must carry a usable
  /// LAN address.
  bool _interfaceSelected(NetworkInterface iface, String pref) {
    if (pref.isNotEmpty) {
      return iface.name.toLowerCase() == pref.toLowerCase();
    }
    for (final addr in iface.addresses) {
      if (NetworkAdapterService.classify(iface.name, addr) ==
          LanAdapterStatus.usable) {
        return true;
      }
    }
    return false;
  }

  /// App resumed — refresh targets and rebind UDP so receive path works again.
  Future<void> recoverAfterNetworkOrResume() async {
    await rebindUdpSocket();
  }

  /// Subnet broadcast(s) for Wi‑Fi/LAN; skips Hyper‑V/WSL virtual NICs and
  /// honors any manual adapter override.
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

    final all = await _adapters.enumerate();
    _hasVirtualLanInterface =
        all.any((a) => a.status == LanAdapterStatus.virtual);
    _hasPhysicalLanInterface = all.any((a) => a.isUsable);

    final pref = AppSettings.instance.preferredAdapterName.value;
    final active =
        NetworkAdapterService.selectActive(all, preferredAdapterName: pref);
    _activeAdapters = active;
    for (final a in active) {
      final b24 = a.broadcast;
      if (b24 != null) addAddr(b24);
    }

    _cachedBroadcastTargets = out;
  }

  List<int> _beaconBytes() {
    final tag = me.lanStableTag.trim();
    final msg = tag.isEmpty
        ? 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort'
        : 'LOCALCHAT|${me.userId}|${me.displayName}|$tcpPort|$tag';
    return utf8.encode(msg);
  }

  void _broadcast() {
    final data = _beaconBytes();
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
      if (addr == null || !NetworkAdapterService.isLanRoutableIpv4(addr)) {
        continue;
      }
      unicastIps.add(ip);
      try {
        _socket?.send(data, addr, udpPort);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Active unicast sweep (Layer 2)
  // ---------------------------------------------------------------------------

  /// Arm the delayed sweep. If peers are still empty after [sweepDelay], walk
  /// every host on each active /24 with directed beacons — needed when the
  /// router blocks wired→Wi‑Fi broadcast and broadcast alone never works.
  void _scheduleSweep() {
    if (kIsWeb) return;
    _sweepDelayTimer?.cancel();
    _searchPhase(DiscoverySearchPhase.searching);
    _sweepDelayTimer = Timer(sweepDelay, () {
      if (_peers.isNotEmpty) return;
      _startSweep();
    });
  }

  void _startSweep() {
    _sweepTimer?.cancel();
    _sweepQueue = _buildSweepHosts();
    _sweepIndex = 0;
    if (_sweepQueue.isEmpty) {
      _searchPhase(DiscoverySearchPhase.exhausted);
      return;
    }
    _searchPhase(DiscoverySearchPhase.scanning);
    _sweepTimer = Timer.periodic(_sweepTick, (_) => _sweepTickFire());
  }

  void _sweepTickFire() {
    if (_peers.isNotEmpty) {
      _stopSweep();
      return;
    }
    var sent = 0;
    while (sent < _sweepHostsPerTick && _sweepIndex < _sweepQueue.length) {
      final addr = _sweepQueue[_sweepIndex++];
      try {
        _socket?.send(_beaconBytes(), addr, udpPort);
      } catch (_) {}
      sent++;
    }
    if (_sweepIndex >= _sweepQueue.length) {
      _sweepTimer?.cancel();
      _sweepTimer = null;
      if (_peers.isEmpty) {
        _searchPhase(DiscoverySearchPhase.exhausted);
      }
    }
  }

  void _stopSweep() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _sweepQueue = const [];
    _sweepIndex = 0;
  }

  /// Every host address on each active adapter's /24, excluding our own IP,
  /// the network (.0), and broadcast (.255). Deduplicated across adapters.
  List<InternetAddress> _buildSweepHosts() {
    final seen = <String>{};
    final hosts = <InternetAddress>[];
    for (final a in _activeAdapters) {
      final r = a.ip.rawAddress;
      if (r.length != 4) continue;
      final own = r[3];
      for (var h = 1; h <= 254; h++) {
        if (h == own) continue;
        final s = '${r[0]}.${r[1]}.${r[2]}.$h';
        if (seen.contains(s)) continue;
        seen.add(s);
        final addr = InternetAddress.tryParse(s);
        if (addr != null) hosts.add(addr);
      }
    }
    return hosts;
  }

  void _searchPhase(DiscoverySearchPhase phase) {
    if (searchPhase.value != phase) searchPhase.value = phase;
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
    final wasEmpty = _peers.isEmpty;

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
    if (wasEmpty) {
      _stopSweep();
      _sweepDelayTimer?.cancel();
      _searchPhase(DiscoverySearchPhase.searching);
    }
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
      if (_peers.isEmpty) _scheduleSweep();
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
    _sweepDelayTimer?.cancel();
    _sweepDelayTimer = null;
    _stopSweep();
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
