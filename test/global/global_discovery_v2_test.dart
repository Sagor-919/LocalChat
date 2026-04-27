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
