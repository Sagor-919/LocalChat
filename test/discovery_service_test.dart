import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/discovery_service.dart';

void main() {
  group('DiscoveryService LAN helpers', () {
    test('isVirtualLanInterfaceName flags Hyper-V/WSL/Docker', () {
      expect(
        DiscoveryService.isVirtualLanInterfaceName('vEthernet (Default Switch)'),
        isTrue,
      );
      expect(DiscoveryService.isVirtualLanInterfaceName('WSL'), isTrue);
      expect(DiscoveryService.isVirtualLanInterfaceName('docker0'), isTrue);
      expect(DiscoveryService.isVirtualLanInterfaceName('Ethernet 3'), isFalse);
      expect(DiscoveryService.isVirtualLanInterfaceName('Wi-Fi'), isFalse);
    });

    test('isLanRoutableIpv4 rejects loopback and APIPA', () {
      expect(
        DiscoveryService.isLanRoutableIpv4(InternetAddress('127.0.0.1')),
        isFalse,
      );
      expect(
        DiscoveryService.isLanRoutableIpv4(InternetAddress('169.254.1.1')),
        isFalse,
      );
      expect(
        DiscoveryService.isLanRoutableIpv4(InternetAddress('192.168.0.155')),
        isTrue,
      );
    });
  });
}
