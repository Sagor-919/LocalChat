import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/network_adapter_service.dart';

void main() {
  group('NetworkAdapterService.isVirtualInterfaceName', () {
    test('flags Hyper-V / WSL / Docker / VM / VPN switches', () {
      const virtual = [
        'vEthernet (Default Switch)',
        'vEthernet (WSL)',
        'vEthernet (WSL (Hyper-V firewall))',
        'DockerNAT',
        'Docker0',
        'Hyper-V Virtual Ethernet Adapter',
        'VMware Network Adapter VMnet1',
        'VirtualBox Host-Only Ethernet Adapter',
        'Tailscale',
        'ZeroTier One [abc123]',
        'OpenVPN TAP-Windows6',
      ];
      for (final name in virtual) {
        expect(
          NetworkAdapterService.isVirtualInterfaceName(name),
          isTrue,
          reason: '$name should be virtual',
        );
      }
    });

    test('does not flag real Wi-Fi / Ethernet', () {
      for (final name in ['Wi-Fi', 'Ethernet', 'Ethernet 3', 'eth0', 'wlan0']) {
        expect(
          NetworkAdapterService.isVirtualInterfaceName(name),
          isFalse,
          reason: '$name should be real',
        );
      }
    });
  });

  group('NetworkAdapterService.isPrivateRfc1918', () {
    test('accepts 10/8, 172.16/12, 192.168/16', () {
      for (final ip in ['10.0.0.5', '172.16.4.1', '172.31.9.9', '192.168.0.155']) {
        expect(NetworkAdapterService.isPrivateRfc1918(InternetAddress(ip)), isTrue,
            reason: '$ip is private');
      }
    });

    test('rejects public, CGNAT, link-local, and 172.x outside 16-31', () {
      for (final ip in ['8.8.8.8', '100.64.0.1', '169.254.1.1', '172.15.0.1', '172.32.0.1']) {
        expect(NetworkAdapterService.isPrivateRfc1918(InternetAddress(ip)), isFalse,
            reason: '$ip is not RFC1918');
      }
    });
  });

  group('NetworkAdapterService.classify', () {
    test('real Wi-Fi with private IP is usable', () {
      expect(
        NetworkAdapterService.classify('Wi-Fi', InternetAddress('192.168.0.156')),
        LanAdapterStatus.usable,
      );
      expect(
        NetworkAdapterService.classify('Ethernet 3', InternetAddress('192.168.0.155')),
        LanAdapterStatus.usable,
      );
    });

    test('Hyper-V Default Switch with private 172.x is virtual, not usable', () {
      // The whole point: the IP looks private but the switch is isolated.
      expect(
        NetworkAdapterService.classify(
            'vEthernet (Default Switch)', InternetAddress('172.22.144.1')),
        LanAdapterStatus.virtual,
      );
      expect(
        NetworkAdapterService.classify('DockerNAT', InternetAddress('10.0.75.1')),
        LanAdapterStatus.virtual,
      );
    });

    test('loopback, link-local, and public addresses', () {
      expect(
        NetworkAdapterService.classify('lo', InternetAddress('127.0.0.1')),
        LanAdapterStatus.loopback,
      );
      expect(
        NetworkAdapterService.classify('Ethernet', InternetAddress('169.254.1.2')),
        LanAdapterStatus.linkLocal,
      );
      expect(
        NetworkAdapterService.classify('Ethernet', InternetAddress('203.0.113.5')),
        LanAdapterStatus.nonPrivate,
      );
    });
  });

  group('NetworkAdapterService.broadcastFor24', () {
    test('computes x.x.x.255 for usable IPs', () {
      expect(
        NetworkAdapterService.broadcastFor24(InternetAddress('192.168.0.155')),
        '192.168.0.255',
      );
    });

    test('returns null for loopback / link-local', () {
      expect(NetworkAdapterService.broadcastFor24(InternetAddress('127.0.0.1')), isNull);
      expect(NetworkAdapterService.broadcastFor24(InternetAddress('169.254.1.1')), isNull);
    });
  });

  group('NetworkAdapterService.selectActive', () {
    final all = [
      LanAdapter(
          name: 'Ethernet 3',
          ip: InternetAddress('192.168.0.155'),
          status: LanAdapterStatus.usable),
      LanAdapter(
          name: 'vEthernet (Default Switch)',
          ip: InternetAddress('172.22.144.1'),
          status: LanAdapterStatus.virtual),
      LanAdapter(
          name: 'Wi-Fi',
          ip: InternetAddress('192.168.0.40'),
          status: LanAdapterStatus.usable),
    ];

    test('auto selects only usable adapters', () {
      final active = NetworkAdapterService.selectActive(all);
      expect(active.map((a) => a.name), ['Ethernet 3', 'Wi-Fi']);
    });

    test('manual override picks the named adapter even if virtual', () {
      final active = NetworkAdapterService.selectActive(all,
          preferredAdapterName: 'vEthernet (Default Switch)');
      expect(active.map((a) => a.name), ['vEthernet (Default Switch)']);
    });

    test('falls back to auto when override no longer matches', () {
      final active =
          NetworkAdapterService.selectActive(all, preferredAdapterName: 'Ethernet 9');
      expect(active.map((a) => a.name), ['Ethernet 3', 'Wi-Fi']);
    });
  });
}
