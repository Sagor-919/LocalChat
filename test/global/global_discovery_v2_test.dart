import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/connection_service.dart';
import 'package:local_chat/device.dart';
import 'package:local_chat/discovery_service.dart';
import 'package:local_chat/global/global_discovery_v2.dart';
import 'package:local_chat/global/global_peer_store.dart';
import 'package:local_chat/global/identity.dart';
import 'package:local_chat/global/nostr_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('LAN online peer wins over global paired peer with same userId', () {
    final shared = 'shared-user-id';
    final global = PeerDevice(
      userId: shared,
      name: 'Global Name',
      ip: '',
      port: 0,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final lan = PeerDevice(
      userId: shared,
      name: 'LAN Name',
      ip: '192.168.1.42',
      port: 4041,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(1),
    );

    final merged = DiscoveryService.mergePeerMaps(
      <String, PeerDevice>{shared: global},
      <String, PeerDevice>{shared: lan},
    );

    expect(merged, hasLength(1));
    expect(merged.single.ip, '192.168.1.42');
    expect(merged.single.name, 'LAN Name');
    expect(merged.single.port, 4041);
  });

  test('Global-only peer survives merge when no LAN entry exists', () {
    final globalOnly = PeerDevice(
      userId: 'only-global',
      name: 'Remote',
      ip: '',
      port: 0,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final merged = DiscoveryService.mergePeerMaps(
      <String, PeerDevice>{'only-global': globalOnly},
      <String, PeerDevice>{},
    );
    expect(merged.single.userId, 'only-global');
    expect(merged.single.ip, isEmpty);
  });

  test('ConnectionService.notifyGlobalDisconnect surfaces on stream', () async {
    final service = ConnectionService(me: _device('me'));
    final received = <String>[];
    final sub = service.disconnectedPeerEvents.listen(received.add);

    var cb = 0;
    service.onDisconnected = (_) => cb++;
    service.notifyGlobalDisconnect('peer-x');
    await Future<void>.delayed(Duration.zero);

    expect(received, ['peer-x']);
    expect(cb, 1);
    await sub.cancel();
    await service.stop();
  });

  test('DiscoveryService merges global peers without replacing LAN peers', () {
    final service = DiscoveryService(me: _device('me'));
    final global = PeerDevice(
      userId: 'peer-1',
      name: 'Global Peer',
      ip: '',
      port: 0,
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );

    var changes = 0;
    service.onPeersChanged = () => changes++;
    service.replaceGlobalPeers([global]);

    expect(service.peers.map((p) => p.userId), ['peer-1']);
    expect(service.peers.single.ip, isEmpty);
    expect(changes, 1);

    service.replaceGlobalPeers([global]);
    expect(changes, 1);

    service.replaceGlobalPeers(const []);
    expect(service.peers, isEmpty);
    expect(changes, 2);
  });

  test(
    'ConnectionService uses global JSON reachability without file support',
    () {
      final service = ConnectionService(me: _device('me'));
      final sent = <Map<String, dynamic>>[];
      service.hasGlobalJsonTransport = (peerId) => peerId == 'global-peer';
      service.sendGlobalJson = (peerId, json) {
        sent.add({'peerId': peerId, ...json});
        return true;
      };

      expect(service.isConnected('global-peer'), isTrue);
      expect(service.isFileTransferAvailable('global-peer'), isFalse);
      expect(service.sendJson('global-peer', {'type': 'message'}), isTrue);
      expect(sent.single, {'peerId': 'global-peer', 'type': 'message'});

      expect(service.sendJson('offline-peer', {'type': 'message'}), isFalse);
    },
  );

  test(
    'GlobalDiscoveryV2 publishes paired peers as V4 PeerDevice entries',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final identity = await _identity(1, 2);
      final peerIdentity = await _identity(3, 4);
      final peer = GlobalPeer(
        userId: peerIdentity.edPubHex,
        name: 'Remote',
        edPub: peerIdentity.edPub,
        xPub: peerIdentity.xPub,
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      await const GlobalPeerStore().savePeer(peer);

      final global = GlobalDiscoveryV2(
        identity: identity,
        peerStore: const GlobalPeerStore(),
        nostr: NostrClient(),
        relayUrls: const [],
        relayConnector: (_) async {},
      );
      await global.reloadPeers();

      expect(global.currentPeers.single.peerId, peer.userId);
      expect(global.peerDevices().single.name, 'Remote');
      expect(global.peerDevices().single.ip, isEmpty);
      await global.close();
    },
  );
}

DeviceInfo _device(String id) {
  return DeviceInfo(userId: id, displayName: id);
}

Future<LocalIdentity> _identity(int edSeedByte, int xSeedByte) async {
  final edPair = await Ed25519().newKeyPairFromSeed(
    List<int>.filled(32, edSeedByte),
  );
  final xPair = await X25519().newKeyPairFromSeed(
    List<int>.filled(32, xSeedByte),
  );
  return LocalIdentity(
    edPriv: await edPair.extractPrivateKeyBytes(),
    edPub: (await edPair.extractPublicKey()).bytes,
    xPriv: await xPair.extractPrivateKeyBytes(),
    xPub: (await xPair.extractPublicKey()).bytes,
  );
}
