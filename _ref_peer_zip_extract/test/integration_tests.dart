import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/device.dart';
import 'package:local_chat/services/device_identity_service.dart';
import 'package:local_chat/services/peer_connection_tracker.dart';
import 'package:local_chat/services/discovery_deduplicator.dart';

void main() {
  group('Integration Tests: Peer Management', () {
    test('Scenario 1: App data clear on same device',
        () async {
      // Simulate first app launch
      var deviceInfo = await DeviceInfo.load();
      final userId1 = deviceInfo.userId;

      // Simulate app data clear
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Simulate app relaunch
      deviceInfo = await DeviceInfo.load();
      final userId2 = deviceInfo.userId;

      // Should be same (recovered from hardware)
      expect(userId1, userId2);
    });

    test('Scenario 2: Device switches from WiFi to Bluetooth', () async {
      // Simulate peer discovery on WiFi
      final peer1 = PeerDevice(
        userId: 'peer1',
        name: 'TestDevice',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );

      // Peer switches to Bluetooth (different IP)
      final peer2 = PeerDevice(
        userId: 'peer1',
        name: 'TestDevice',
        ip: '192.168.4.50',
        port: 4041,
        lastSeen: DateTime.now(),
      );

      // Should detect as same device, just update IP
      expect(
        DiscoveryDeduplicator.isSamePeerDifferentInterface(
          peer1,
          peer2.name,
          peer2.ip,
          peer2.port,
        ),
        true,
      );

      // Merge should keep same userId
      final merged = DiscoveryDeduplicator.mergePeers(
        peer1,
        peer2.name,
        peer2.ip,
        peer2.port,
        DateTime.now(),
      );

      expect(merged.userId, peer1.userId);
      expect(merged.ip, peer2.ip);
    });

    test('Scenario 3: Peer reconnection after network glitch', () async {
      // Simulate peer going offline then back online
      final tracker = PeerConnectionTracker(
        discovery: mockDiscovery,
        connections: mockConnections,
      );

      // Initial: peer online
      final peer = PeerDevice(
        userId: 'peer1',
        name: 'Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );

      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();
      expect(tracker.getState('peer1'), PeerState.online);

      // Network glitch: peer disappears
      mockDiscovery.setPeers([]);
      mockDiscovery.triggerOnPeersChanged();
      expect(tracker.getState('peer1'), PeerState.transitioning);

      // Peer quickly reappears (within grace period)
      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();
      expect(tracker.getState('peer1'), PeerState.online);
    });

    test('Scenario 4: Multiple peers with mixed states', () async {
      final tracker = PeerConnectionTracker(
        discovery: mockDiscovery,
        connections: mockConnections,
      );

      // Start with 3 peers online
      final peers = [
        PeerDevice(
          userId: 'peer1',
          name: 'Peer1',
          ip: '192.168.1.100',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
        PeerDevice(
          userId: 'peer2',
          name: 'Peer2',
          ip: '192.168.1.101',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
        PeerDevice(
          userId: 'peer3',
          name: 'Peer3',
          ip: '192.168.1.102',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
      ];

      mockDiscovery.setPeers(peers);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getPeersByState(PeerState.online).length, 3);

      // peer1 goes offline
      mockDiscovery.setPeers([peers[1], peers[2]]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getPeersByState(PeerState.online).length, 2);
      expect(tracker.getPeersByState(PeerState.transitioning).length, 1);

      // peer1 reconnects while peer2 goes offline
      mockDiscovery.setPeers([peers[0], peers[2]]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getPeersByState(PeerState.online).length, 2);
      expect(tracker.getPeersByState(PeerState.transitioning).length, 1);
    });
  });
}