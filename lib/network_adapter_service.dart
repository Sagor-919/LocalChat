import 'dart:io';

import 'package:flutter/foundation.dart';

/// How a single IPv4 address on a network interface is treated for LAN
/// discovery. Only [usable] adapters carry broadcast/sweep traffic.
enum LanAdapterStatus {
  /// Real Wi‑Fi/Ethernet with a private RFC1918 address — use for discovery.
  usable,

  /// Hyper‑V / WSL / Docker / VPN / VMware / VirtualBox host-only switch, etc.
  /// These do not reach the phone's LAN even when the IP looks private
  /// (e.g. Hyper‑V Default Switch on `172.x`).
  virtual,

  /// Loopback (`127.x`).
  loopback,

  /// APIPA / link-local (`169.254.x`) — no DHCP lease, not a real LAN.
  linkLocal,

  /// Routable but not RFC1918 (public / CGNAT) — skip for LAN discovery.
  nonPrivate,
}

/// One IPv4 address on one interface, classified for discovery.
@immutable
class LanAdapter {
  final String name;
  final InternetAddress ip;
  final LanAdapterStatus status;

  const LanAdapter({
    required this.name,
    required this.ip,
    required this.status,
  });

  bool get isUsable => status == LanAdapterStatus.usable;

  /// `x.x.x.255` directed subnet broadcast for this address (assumes /24).
  String? get broadcast => NetworkAdapterService.broadcastFor24(ip);

  /// Short human-readable reason this adapter is used or ignored — for the
  /// settings/debug screen.
  String get reason => switch (status) {
        LanAdapterStatus.usable => 'Real LAN adapter (private IPv4)',
        LanAdapterStatus.virtual =>
          'Virtual switch (Hyper‑V/WSL/Docker/VPN/VM) — not the phone\u2019s LAN',
        LanAdapterStatus.loopback => 'Loopback',
        LanAdapterStatus.linkLocal => 'Link-local / no DHCP (169.254.x)',
        LanAdapterStatus.nonPrivate => 'Not a private LAN IP (public/CGNAT)',
      };

  @override
  String toString() => 'LanAdapter($name, ${ip.address}, $status)';
}

/// Enumerates and classifies IPv4 interfaces so discovery only advertises on
/// real LAN adapters where peers actually live.
///
/// Key insight: a virtual switch (Hyper‑V "Default Switch", Docker NAT, WSL)
/// can hold a private `172.x`/`10.x` address yet be an isolated VM network. The
/// app must exclude it by **name** even though the IP looks private.
class NetworkAdapterService {
  const NetworkAdapterService();

  /// Interface name fragments that indicate a host-only / virtual / VPN NIC.
  static const List<String> _virtualNameFragments = [
    'vethernet',
    'hyper-v',
    'hyperv',
    'wsl',
    'docker',
    'virtualbox',
    'vmware',
    'vmnet',
    'vpn',
    'tailscale',
    'zerotier',
    'tap',
    'tun',
    'loopback',
    'bluetooth',
    'npcap',
    'pseudo',
    'default switch',
  ];

  /// True when the interface name looks like a host-only virtual switch, VPN, or
  /// tunnel — not the LAN where phones live.
  static bool isVirtualInterfaceName(String name) {
    final n = name.toLowerCase();
    for (final frag in _virtualNameFragments) {
      if (n.contains(frag)) return true;
    }
    return false;
  }

  /// APIPA / link-local IPv4 (`169.254.0.0/16`).
  static bool isLinkLocalIpv4(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4) return false;
    final r = addr.rawAddress;
    return r.length == 4 && r[0] == 169 && r[1] == 254;
  }

  /// RFC1918 private IPv4: `10/8`, `172.16/12`, `192.168/16`.
  static bool isPrivateRfc1918(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4) return false;
    final r = addr.rawAddress;
    if (r.length != 4) return false;
    if (r[0] == 10) return true;
    if (r[0] == 172 && r[1] >= 16 && r[1] <= 31) return true;
    if (r[0] == 192 && r[1] == 168) return true;
    return false;
  }

  /// IPv4 usable as a discovery source (not loopback / link-local). Kept for
  /// callers that only need a coarse routability check.
  static bool isLanRoutableIpv4(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return false;
    return !isLinkLocalIpv4(addr);
  }

  /// `x.x.x.255` for a /24, or null when [addr] is not a usable IPv4.
  static String? broadcastFor24(InternetAddress addr) {
    if (!isLanRoutableIpv4(addr)) return null;
    final r = addr.rawAddress;
    return '${r[0]}.${r[1]}.${r[2]}.255';
  }

  /// Classifies one IPv4 [addr] on an interface named [name].
  static LanAdapterStatus classify(String name, InternetAddress addr) {
    if (addr.isLoopback) return LanAdapterStatus.loopback;
    if (isLinkLocalIpv4(addr)) return LanAdapterStatus.linkLocal;
    if (isVirtualInterfaceName(name)) return LanAdapterStatus.virtual;
    if (!isPrivateRfc1918(addr)) return LanAdapterStatus.nonPrivate;
    return LanAdapterStatus.usable;
  }

  /// All IPv4 addresses across interfaces, each classified. Includes loopback
  /// and link-local so the settings/debug screen can explain what was ignored.
  Future<List<LanAdapter>> enumerate() async {
    if (kIsWeb) return const [];
    final out = <LanAdapter>[];
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: true,
        includeLinkLocal: true,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          out.add(LanAdapter(
            name: iface.name,
            ip: addr,
            status: classify(iface.name, addr),
          ));
        }
      }
    } catch (_) {}
    return out;
  }

  /// Adapters that should carry discovery traffic.
  ///
  /// With no [preferredAdapterName], returns every [LanAdapterStatus.usable]
  /// adapter. When the user picks a manual override, returns the matching
  /// adapter(s) by name regardless of classification (user choice wins), but
  /// falls back to auto if no adapter matches the saved name (e.g. unplugged).
  static List<LanAdapter> selectActive(
    List<LanAdapter> all, {
    String? preferredAdapterName,
  }) {
    final pref = preferredAdapterName?.trim() ?? '';
    if (pref.isNotEmpty) {
      final matches = all
          .where((a) => a.name.toLowerCase() == pref.toLowerCase())
          .toList();
      if (matches.isNotEmpty) return matches;
    }
    return all.where((a) => a.isUsable).toList();
  }
}
