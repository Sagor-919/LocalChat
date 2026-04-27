import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../device.dart';
import 'global_peer_store.dart';
import 'identity.dart';
import 'noise_session.dart';
import 'nostr_client.dart';
import 'rendezvous_service.dart';
import 'webrtc_session.dart';

enum GlobalPeerReachability { paired, connecting, connected, failed }

class GlobalPeerSnapshot {
  const GlobalPeerSnapshot({required this.peer, required this.reachability});

  final GlobalPeer peer;
  final GlobalPeerReachability reachability;

  String get peerId => peer.userId;
  bool get isConnected => reachability == GlobalPeerReachability.connected;

  PeerDevice toPeerDevice() {
    return PeerDevice(
      userId: peerId,
      name: peer.name,
      ip: '',
      port: 0,
      lastSeen: DateTime.now(),
    );
  }
}

class GlobalJsonMessage {
  const GlobalJsonMessage({required this.peerId, required this.json});

  final String peerId;
  final Map<String, dynamic> json;
}

typedef WebRtcSessionFactory = WebRtcSession Function();
typedef RelayConnector = Future<void> Function(List<String> relayUrls);

class GlobalDiscoveryV2 {
  GlobalDiscoveryV2({
    required this.identity,
    required this.peerStore,
    required this.nostr,
    required List<String> relayUrls,
    WebRtcSessionFactory? webRtcSessionFactory,
    RelayConnector? relayConnector,
  }) : _relayUrls = relayUrls,
       _webRtcSessionFactory = webRtcSessionFactory ?? WebRtcSession.new,
       _relayConnector = relayConnector ?? nostr.connect;

  final LocalIdentity identity;
  final GlobalPeerStore peerStore;
  final NostrClient nostr;
  final List<String> _relayUrls;
  final WebRtcSessionFactory _webRtcSessionFactory;
  final RelayConnector _relayConnector;

  final ValueNotifier<List<GlobalPeerSnapshot>> peers =
      ValueNotifier<List<GlobalPeerSnapshot>>(const <GlobalPeerSnapshot>[]);
  final StreamController<GlobalJsonMessage> _messages =
      StreamController<GlobalJsonMessage>.broadcast();
  final StreamController<String> _disconnects =
      StreamController<String>.broadcast();

  final Map<String, GlobalPeer> _peersById = <String, GlobalPeer>{};
  final Map<String, GlobalPeerReachability> _reachability =
      <String, GlobalPeerReachability>{};
  final Map<String, _PeerChannel> _channels = <String, _PeerChannel>{};
  final List<NostrSubscription> _peerSubscriptions = <NostrSubscription>[];

  RendezvousService? _rendezvous;
  StreamSubscription<RendezvousMessage>? _rendezvousSub;
  bool _enabled = false;

  Stream<GlobalJsonMessage> get messages => _messages.stream;
  Stream<String> get disconnectedPeerEvents => _disconnects.stream;
  List<GlobalPeerSnapshot> get currentPeers => peers.value;

  Future<void> start() async {
    if (_enabled) return;
    _enabled = true;
    await _relayConnector(_relayUrls);
    _rendezvous = RendezvousService(identity: identity, nostr: nostr);
    _rendezvousSub = _rendezvous!.messages.listen(_handleRendezvous);
    await reloadPeers();
  }

  Future<void> stop() async {
    _enabled = false;
    for (final subscription in _peerSubscriptions) {
      subscription.cancel();
    }
    _peerSubscriptions.clear();
    await _rendezvousSub?.cancel();
    _rendezvousSub = null;
    await _rendezvous?.close();
    _rendezvous = null;
    for (final entry in List<MapEntry<String, _PeerChannel>>.from(
      _channels.entries,
    )) {
      if (!_disconnects.isClosed) _disconnects.add(entry.key);
      await entry.value.close();
    }
    _channels.clear();
    _reachability.clear();
    _publishSnapshots();
    await nostr.close();
  }

  Future<void> close() async {
    await stop();
    await _messages.close();
    await _disconnects.close();
    peers.dispose();
  }

  Future<void> reloadPeers() async {
    final loaded = await peerStore.loadPeers();
    _peersById
      ..clear()
      ..addEntries(loaded.map((peer) => MapEntry(peer.userId, peer)));
    _reachability.removeWhere((peerId, _) => !_peersById.containsKey(peerId));
    for (final peer in loaded) {
      _reachability.putIfAbsent(
        peer.userId,
        () => GlobalPeerReachability.paired,
      );
    }
    _resubscribeRendezvous();
    _publishSnapshots();
  }

  Future<void> removePeer(String peerId) async {
    final peer = _peersById[peerId];
    if (peer == null) return;
    await peerStore.removePeer(peer.edPubHex);
    await _channels.remove(peerId)?.close();
    await reloadPeers();
  }

  bool isConnected(String peerId) {
    return _channels[peerId]?.isEstablished == true;
  }

  Future<bool> connectToPeerId(String peerId) async {
    if (!_enabled) return false;
    final peer = _peersById[peerId];
    final rendezvous = _rendezvous;
    if (peer == null || rendezvous == null) return false;
    final existing = _channels[peerId];
    if (existing != null && !existing.isClosed) return true;

    final channel = _openChannel(peer, NoiseRole.initiator);
    try {
      await channel.session.connectAsCaller(peer, rendezvous);
      return true;
    } catch (_) {
      _markFailed(peerId);
      return false;
    }
  }

  bool sendJson(String peerId, Map<String, dynamic> json) {
    final channel = _channels[peerId];
    if (channel == null || !channel.isEstablished) return false;
    unawaited(
      channel.sendJson(json).catchError((_) {
        _markFailed(peerId);
      }),
    );
    return true;
  }

  List<PeerDevice> peerDevices() {
    return [for (final snapshot in peers.value) snapshot.toPeerDevice()];
  }

  _PeerChannel _openChannel(GlobalPeer peer, NoiseRole role) {
    final peerId = peer.userId;
    _reachability[peerId] = GlobalPeerReachability.connecting;
    _publishSnapshots();

    final channel = _PeerChannel(
      peer: peer,
      role: role,
      session: _webRtcSessionFactory(),
      noise: role == NoiseRole.initiator
          ? NoiseSession.initiator(identity, peer)
          : NoiseSession.responder(identity, peer),
      onEstablished: () {
        _reachability[peerId] = GlobalPeerReachability.connected;
        _publishSnapshots();
      },
      onFailed: () => _markFailed(peerId),
      onJson: (json) {
        if (!_messages.isClosed) {
          _messages.add(GlobalJsonMessage(peerId: peerId, json: json));
        }
      },
    );
    _channels[peerId] = channel;
    channel.attach();
    return channel;
  }

  void _handleRendezvous(RendezvousMessage message) {
    if (message.kind != RendezvousMessageKind.webrtcOffer) return;
    final peer = _peersById[message.from];
    final rendezvous = _rendezvous;
    if (peer == null || rendezvous == null || !_enabled) return;
    if (_channels[peer.userId]?.isClosed == false) return;

    final channel = _openChannel(peer, NoiseRole.responder);
    unawaited(
      channel.session
          .acceptAsCallee(peer, message, rendezvous)
          .catchError((_) => _markFailed(peer.userId)),
    );
  }

  void _resubscribeRendezvous() {
    for (final subscription in _peerSubscriptions) {
      subscription.cancel();
    }
    _peerSubscriptions.clear();
    final rendezvous = _rendezvous;
    if (rendezvous == null) return;
    for (final peer in _peersById.values) {
      _peerSubscriptions.add(rendezvous.subscribeForPeer(peer));
    }
  }

  void _markFailed(String peerId) {
    final channel = _channels.remove(peerId);
    if (channel != null && !channel.isClosed) {
      if (!_disconnects.isClosed) _disconnects.add(peerId);
      unawaited(channel.close());
    }
    if (_peersById.containsKey(peerId)) {
      _reachability[peerId] = GlobalPeerReachability.failed;
      _publishSnapshots();
    }
  }

  void _publishSnapshots() {
    final snapshots =
        <GlobalPeerSnapshot>[
          for (final peer in _peersById.values)
            GlobalPeerSnapshot(
              peer: peer,
              reachability:
                  _reachability[peer.userId] ?? GlobalPeerReachability.paired,
            ),
        ]..sort(
          (a, b) =>
              a.peer.name.toLowerCase().compareTo(b.peer.name.toLowerCase()),
        );
    peers.value = snapshots;
  }
}

class _PeerChannel {
  _PeerChannel({
    required this.peer,
    required this.role,
    required this.session,
    required this.noise,
    required this.onEstablished,
    required this.onFailed,
    required this.onJson,
  });

  final GlobalPeer peer;
  final NoiseRole role;
  final WebRtcSession session;
  final NoiseSession noise;
  final VoidCallback onEstablished;
  final VoidCallback onFailed;
  final void Function(Map<String, dynamic> json) onJson;

  StreamSubscription<WebRtcSessionState>? _stateSub;
  StreamSubscription<List<int>>? _incomingSub;
  bool _initiatorHandshakeStarted = false;
  bool _closed = false;

  bool get isEstablished => noise.isEstablished && !_closed;
  bool get isClosed => _closed;

  void attach() {
    _stateSub = session.states.listen((state) {
      if (state == WebRtcSessionState.connected &&
          role == NoiseRole.initiator) {
        unawaited(_startInitiatorHandshake());
      } else if (state == WebRtcSessionState.failed ||
          state == WebRtcSessionState.closed) {
        onFailed();
      }
    });
    _incomingSub = session.incoming.listen(
      (bytes) => unawaited(_handleIncoming(bytes)),
      onError: (_) => onFailed(),
    );
  }

  Future<void> sendJson(Map<String, dynamic> json) async {
    final frame = await noise.encrypt(utf8.encode(jsonEncode(json)));
    await session.send(frame);
  }

  Future<void> close() async {
    _closed = true;
    await _stateSub?.cancel();
    await _incomingSub?.cancel();
    await session.close();
  }

  Future<void> _startInitiatorHandshake() async {
    if (_initiatorHandshakeStarted || _closed) return;
    _initiatorHandshakeStarted = true;
    await session.send(await noise.startHandshakeMessage());
  }

  Future<void> _handleIncoming(List<int> bytes) async {
    if (_closed) return;
    try {
      if (!noise.isEstablished) {
        final response = await noise.handleHandshakeMessage(bytes);
        if (response != null) await session.send(response);
        if (noise.isEstablished) onEstablished();
        return;
      }

      final plaintext = await noise.decrypt(bytes);
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is Map) {
        onJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      onFailed();
    }
  }
}
