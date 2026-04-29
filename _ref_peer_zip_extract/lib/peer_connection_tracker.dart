import 'package:flutter/foundation.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'connection_service.dart';

enum PeerState {
  online,      // In discovery, active TCP
  transitioning, // Last seen within 15s, awaiting TCP
  offline,     // Not in discovery, TCP closed
  stale,       // Hasn't been seen in 30s+ (zombie state)
}

class PeerConnectionTracker extends ChangeNotifier {
  final DiscoveryService discovery;
  final ConnectionService connections;
  final Map<String, PeerConnectionState> _peerStates = {};

  Timer? _cleanupTimer;
  Timer? _transitionTimer;

  PeerConnectionTracker({
    required this.discovery,
    required this.connections,
  }) {
    discovery.onPeersChanged = _onDiscoveryChanged;
    connections.onDisconnected = _onConnectionDisconnected;
    _startCleanupTimer();
  }

  void _onDiscoveryChanged() {
    // Update all discovered peers immediately
    for (final peer in discovery.peers) {
      final state = _peerStates[peer.userId];
      if (state == null) {
        _peerStates[peer.userId] = PeerConnectionState(
          peer: peer,
          state: PeerState.online,
          lastSeen: DateTime.now(),
        );
      } else {
        state.peer = peer;
        state.lastSeen = DateTime.now();
        if (state.state != PeerState.online) {
          state.state = PeerState.online;
        }
      }
    }

    // Mark peers not in discovery as transitioning (grace period)
    final discoveredIds = discovery.peers.map((p) => p.userId).toSet();
    for (final entry in _peerStates.entries) {
      if (!discoveredIds.contains(entry.key) && 
          entry.value.state == PeerState.online) {
        entry.value.state = PeerState.transitioning;
        entry.value.transitionStarted = DateTime.now();
      }
    }

    notifyListeners();
  }

  void _onConnectionDisconnected(String peerId) {
    final state = _peerStates[peerId];
    if (state != null && state.state != PeerState.offline) {
      state.state = PeerState.offline;
      state.tcpConnected = false;
      notifyListeners();
    }
  }

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(Duration(seconds: 5), (_) {
      _cleanupStaleEntries();
    });
  }

  void _cleanupStaleEntries() {
    final now = DateTime.now();
    bool changed = false;

    for (final entry in _peerStates.entries) {
      final timeSinceLastSeen = now.difference(entry.value.lastSeen);
      
      // If transitioning for >15s and no TCP, mark offline
      if (entry.value.state == PeerState.transitioning) {
        if (timeSinceLastSeen > Duration(seconds: 15) &&
            !entry.value.tcpConnected) {
          entry.value.state = PeerState.offline;
          changed = true;
        }
      }
      
      // If offline and no message history, mark stale after 30s
      if (entry.value.state == PeerState.offline &&
          timeSinceLastSeen > Duration(seconds: 30)) {
        entry.value.state = PeerState.stale;
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  PeerState getState(String peerId) => 
    _peerStates[peerId]?.state ?? PeerState.offline;

  List<String> getPeersByState(PeerState state) =>
    _peerStates.entries
      .where((e) => e.value.state == state)
      .map((e) => e.key)
      .toList();

  void dispose() {
    _cleanupTimer?.cancel();
    discovery.onPeersChanged = null;
    connections.onDisconnected = null;
    super.dispose();
  }
}

class PeerConnectionState {
  PeerDevice peer;
  PeerState state;
  DateTime lastSeen;
  DateTime? transitionStarted;
  bool tcpConnected = false;

  PeerConnectionState({
    required this.peer,
    required this.state,
    required this.lastSeen,
  });
}