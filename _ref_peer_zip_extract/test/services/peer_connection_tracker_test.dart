import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/services/peer_connection_tracker.dart';
import 'package:local_chat/device.dart';
import 'package:local_chat/discovery_service.dart';
import 'package:local_chat/connection_service.dart';

void main() {
  group('PeerConnectionTracker', () {
    late MockDiscoveryService mockDiscovery;
    late MockConnectionService mockConnections;
    late PeerConnectionTracker tracker;

    setUp(() {
      mockDiscovery = MockDiscoveryService();
      mockConnections = MockConnectionService();
      tracker = PeerConnectionTracker(
        discovery: mockDiscovery,
        connections: mockConnections,
      );
    });

    tearDown(() {
      tracker.dispose();
    });

    test('Initial state: all peers are offline', () {
      expect(tracker.getState('peer1'), PeerState.offline);
      expect(tracker.getAllPeers().length, 0);
    });

    test('Discovery callback: adds peer as online', () {
      final peer = PeerDevice(
        userId: 'peer1',
        name: 'Test Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );

      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getState('peer1'), PeerState.online);
      expect(tracker.isOnline('peer1'), true);
    });

    test('Peer disappears from discovery: transitions to transitioning', () {
      // Setup: peer online
      final peer = PeerDevice(
        userId: 'peer1',
        name: 'Test Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );
      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getState('peer1'), PeerState.online);

      // Peer disappears
      mockDiscovery.setPeers([]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getState('peer1'), PeerState.transitioning);
    });

    test('Peer reappears during transitioning: back to online', () {
      // Setup: peer was online, then disappeared
      var peer = PeerDevice(
        userId: 'peer1',
        name: 'Test Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );
      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();

      mockDiscovery.setPeers([]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getState('peer1'), PeerState.transitioning);

      // Peer reappears
      peer = PeerDevice(
        userId: 'peer1',
        name: 'Test Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );
      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.getState('peer1'), PeerState.online);
    });

    test('TCP connection marked: updates tcpConnected flag', () {
      // Setup: peer discovered
      final peer = PeerDevice(
        userId: 'peer1',
        name: 'Test Peer',
        ip: '192.168.1.100',
        port: 4041,
        lastSeen: DateTime.now(),
      );
      mockDiscovery.setPeers([peer]);
      mockDiscovery.triggerOnPeersChanged();

      // Mark TCP connected
      tracker.markTcpConnected('peer1');

      final state = tracker.getStateObject('peer1');
      expect(state?.tcpConnected, true);
    });

    test('Reconnect backoff: increases with attempts', () {
      tracker.incrementReconnectAttempts('peer1');
      expect(tracker.getReconnectBackoff('peer1').inMilliseconds, 100);

      tracker.incrementReconnectAttempts('peer1');
      expect(tracker.getReconnectBackoff('peer1').inMilliseconds, 200);

      tracker.incrementReconnectAttempts('peer1');
      expect(tracker.getReconnectBackoff('peer1').inMilliseconds, 400);

      // Capped at 1000
      tracker.incrementReconnectAttempts('peer1');
      expect(tracker.getReconnectBackoff('peer1').inMilliseconds, 1000);
    });

    test('Multiple peers: tracks state independently', () {
      // Add 3 peers
      final peers = [
        PeerDevice(
          userId: 'peer1',
          name: 'Peer 1',
          ip: '192.168.1.100',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
        PeerDevice(
          userId: 'peer2',
          name: 'Peer 2',
          ip: '192.168.1.101',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
        PeerDevice(
          userId: 'peer3',
          name: 'Peer 3',
          ip: '192.168.1.102',
          port: 4041,
          lastSeen: DateTime.now(),
        ),
      ];

      mockDiscovery.setPeers(peers);
      mockDiscovery.triggerOnPeersChanged();

      // All online
      expect(tracker.isOnline('peer1'), true);
      expect(tracker.isOnline('peer2'), true);
      expect(tracker.isOnline('peer3'), true);

      // Remove peer1 and peer3
      mockDiscovery.setPeers([peers[1]]);
      mockDiscovery.triggerOnPeersChanged();

      expect(tracker.isTransitioning('peer1'), true);
      expect(tracker.isOnline('peer2'), true);
      expect(tracker.isTransitioning('peer3'), true);
    });
  });
}

// Mock implementations
class MockDiscoveryService extends DiscoveryService {
  final List<PeerDevice> _peers = [];

  MockDiscoveryService()
      : super(me: DeviceInfo(userId: 'test', displayName: 'Test Device'));

  void setPeers(List<PeerDevice> peers) {
    _peers.clear();
    _peers.addAll(peers);
  }

  void triggerOnPeersChanged() {
    onPeersChanged?.call();
  }

  @override
  List<PeerDevice> get peers => _peers;

  @override
  Future<void> start() async {}

  @override
  Future<void> recoverAfterNetworkOrResume() async {}

  @override
  Future<void> rebindUdpSocket() async {}

  @override
  void stop() {}
}

class MockConnectionService extends ConnectionService {
  MockConnectionService()
      : super(me: DeviceInfo(userId: 'test', displayName: 'Test Device'));

  void triggerOnDisconnected(String peerId) {
    onDisconnected?.call(peerId);
  }

  @override
  Future<void> startServer() async {}

  @override
  Future<Socket?> connectTo(PeerDevice peer, {bool forceNew = false}) async {
    return null;
  }

  @override
  Future<void> stop() async {}
}