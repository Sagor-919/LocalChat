import 'package:flutter/foundation.dart';
import 'dart:async';

import '../device.dart';
import '../discovery_service.dart';
import '../connection_service.dart';

/// Peer connection state for state machine.
enum PeerState {
  /// In discovery list AND has active TCP connection.
  /// Green indicator.
  online,

  /// Was online, disappeared from discovery, but still within grace period.
  /// Prevents false "offline" during network hiccups.
  /// Yellow/Loading indicator.
  transitioning,

  /// Not in discovery AND no TCP connection.
  /// Waited 15s after last transitioning state.
  /// Gray/Offline indicator.
  offline,

  /// Offline for 30+ seconds with no message history.
  /// Can be pruned from UI.
  stale,
}

/// Tracks individual peer connection state and lifecycle.
class PeerConnectionState {
  /// Peer device information (name, IP, port).
  PeerDevice peer;

  /// Current connection state (online/transitioning/offline/stale).
  PeerState state;

  /// When peer was last seen in discovery.
  DateTime lastSeen;

  /// When peer transitioned to "transitioning" state.
  /// Used to calculate grace period.
  DateTime? transitionStarted;

  /// Whether peer has active TCP connection.
  bool tcpConnected;

  /// Attempt count since last successful connection.
  /// Used to implement exponential backoff.
  int reconnectAttempts;

  /// When we last attempted to connect via TCP.
  DateTime? lastConnectionAttempt;

  PeerConnectionState({
    required this.peer,
    required this.state,
    required this.lastSeen,
    this.tcpConnected = false,
    this.reconnectAttempts = 0,
    this.transitionStarted,
    this.lastConnectionAttempt,
  });

  /// Human-readable state label for UI.
  String get stateLabel {
    switch (state) {
      case PeerState.online:
        return 'Online';
      case PeerState.transitioning:
        return 'Reconnecting...';
      case PeerState.offline:
        return 'Offline';
      case PeerState.stale:
        return 'Offline';
    }
  }

  /// Icon indicator based on state.
  IconData get stateIcon {
    switch (state) {
      case PeerState.online:
        return Icons.check_circle;
      case PeerState.transitioning:
        return Icons.schedule;
      case PeerState.offline:
        return Icons.cancel;
      case PeerState.stale:
        return Icons.cancel;
    }
  }

  /// Color indicator based on state.
  Color get stateColor {
    switch (state) {
      case PeerState.online:
        return Colors.green;
      case PeerState.transitioning:
        return Colors.orange;
      case PeerState.offline:
        return Colors.grey;
      case PeerState.stale:
        return Colors.grey;
    }
  }
}

/// Manages peer connection tracking and state transitions.
/// 
/// Responsibilities:
/// 1. Listen to discovery service for peer changes
/// 2. Listen to connection service for TCP connect/disconnect
/// 3. Maintain state machine per peer
/// 4. Trigger cleanups and state transitions
/// 5. Notify listeners on state changes
/// 
/// This decouples peer tracking from UI layer, enabling:
/// - Efficient partial UI updates (only changed peers)
/// - Consistent state across multiple screens
/// - Testable state logic
/// - Clear lifecycle management
class PeerConnectionTracker extends ChangeNotifier {
  /// Reference to discovery service for listening to peer changes.
  final DiscoveryService discovery;

  /// Reference to connection service for TCP connection tracking.
  final ConnectionService connections;

  /// Peer ID -> Peer connection state mapping.
  final Map<String, PeerConnectionState> _peerStates = {};

  /// Periodic timer for cleanup and state transitions.
  Timer? _cleanupTimer;

  /// Timers per peer for transitioning grace period.
  final Map<String, Timer> _transitionGraceTimers = {};

  // Configuration constants - adjust these to tune behavior
  static const Duration _transitionGracePeriod = Duration(seconds: 15);
  static const Duration _staleTimeout = Duration(seconds: 30);
  static const Duration _cleanupInterval = Duration(seconds: 5);

  PeerConnectionTracker({
    required this.discovery,
    required this.connections,
  }) {
    _initialize();
  }

  void _initialize() {
    // Subscribe to discovery changes
    discovery.onPeersChanged = _onDiscoveryChanged;

    // Subscribe to connection changes
    connections.onDisconnected = _onConnectionDisconnected;

    // Start periodic cleanup
    _startCleanupTimer();
  }

  /// Called when discovery service detects peer changes.
  /// 
  /// Updates peer online status based on current discovery list.
  /// Starts grace period timers for disappearing peers.
  void _onDiscoveryChanged() {
    if (!kDebugMode) return; // Safety check

    _updateFromDiscovery();
    notifyListeners();
  }

  /// Called when peer TCP connection is lost.
  /// 
  /// Marks peer as no longer TCP-connected.
  /// Will be marked offline if not in discovery.
  void _onConnectionDisconnected(String peerId) {
    final state = _peerStates[peerId];
    if (state != null) {
      state.tcpConnected = false;
      state.reconnectAttempts = 0; // Reset on successful disconnect

      // If not in discovery, transition to offline
      if (state.state != PeerState.offline &&
          state.state != PeerState.stale) {
        // Only transition if not already transitioning
        if (state.state == PeerState.online) {
          state.state = PeerState.transitioning;
          state.transitionStarted = DateTime.now();
          _startTransitionGraceTimer(peerId);
        }
      }

      notifyListeners();
    }
  }

  /// Update peer states from discovery service.
  /// 
  /// For each peer in discovery:
  /// 1. If not in _peerStates: create new entry
  /// 2. If in _peerStates: update lastSeen, cancel grace timer
  /// 3. If was transitioning: revert to online
  /// 
  /// For peers not in discovery:
  /// 1. If online: transition to transitioning with grace timer
  void _updateFromDiscovery() {
    final discoveredPeers = discovery.peers;
    final discoveredIds =
        discoveredPeers.map((p) => p.userId).toSet();

    // Update discovered peers - mark as online
    for (final peer in discoveredPeers) {
      final state = _peerStates[peer.userId];

      if (state == null) {
        // New peer discovered
        _peerStates[peer.userId] = PeerConnectionState(
          peer: peer,
          state: PeerState.online,
          lastSeen: DateTime.now(),
        );
      } else {
        // Existing peer still in discovery
        state.peer = peer;
        state.lastSeen = DateTime.now();

        // Cancel grace timer if still transitioning
        _transitionGraceTimers[peer.userId]?.cancel();
        _transitionGraceTimers.remove(peer.userId);

        // Revert to online if was transitioning
        if (state.state == PeerState.transitioning) {
          state.state = PeerState.online;
        }
      }
    }

    // Mark peers not in discovery as transitioning (with grace period)
    for (final entry in _peerStates.entries) {
      if (!discoveredIds.contains(entry.key)) {
        final state = entry.value;

        if (state.state == PeerState.online) {
          // Was online, now disappeared - start grace period
          state.state = PeerState.transitioning;
          state.transitionStarted = DateTime.now();
          _startTransitionGraceTimer(entry.key);
        }
      }
    }
  }

  /// Start grace period timer for transitioning peer.
  /// 
  /// After 15 seconds without reappearing, mark as offline.
  void _startTransitionGraceTimer(String peerId) {
    // Cancel existing timer if any
    _transitionGraceTimers[peerId]?.cancel();

    _transitionGraceTimers[peerId] = Timer(
      _transitionGracePeriod,
      () {
        _onTransitionGraceExpired(peerId);
      },
    );
  }

  /// Called when grace period for transitioning peer expires.
  /// 
  /// If peer still not in discovery and no TCP connection: mark offline.
  void _onTransitionGraceExpired(String peerId) {
    _transitionGraceTimers.remove(peerId);

    final state = _peerStates[peerId];
    if (state != null && state.state == PeerState.transitioning) {
      // If still not in discovery and no TCP: mark offline
      if (!discovery.peers.any((p) => p.userId == peerId) &&
          !state.tcpConnected) {
        state.state = PeerState.offline;
        notifyListeners();
      }
    }
  }

  /// Periodic cleanup timer for stale entry removal.
  /// 
  /// Runs every 5 seconds to:
  /// 1. Mark very old offline peers as stale
  /// 2. Log state transitions (debug)
  /// 3. Check for consistency issues
  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(
      _cleanupInterval,
      (_) => _performCleanup(),
    );
  }

  /// Perform periodic cleanup tasks.
  void _performCleanup() {
    final now = DateTime.now();
    bool changed = false;

    for (final entry in _peerStates.entries) {
      final state = entry.value;
      final timeSinceLastSeen = now.difference(state.lastSeen);

      // Mark offline peers as stale after 30 seconds
      if (state.state == PeerState.offline &&
          timeSinceLastSeen > _staleTimeout) {
        state.state = PeerState.stale;
        changed = true;

        if (kDebugMode) {
          print('[PeerTracker] ${state.peer.name} marked as stale');
        }
      }
    }

    if (changed) {
      notifyListeners();
    }
  }

  // --------- Public API ---------

  /// Get current state of a peer.
  PeerState getState(String peerId) =>
      _peerStates[peerId]?.state ?? PeerState.offline;

  /// Get state object for a peer (includes metadata).
  PeerConnectionState? getStateObject(String peerId) =>
      _peerStates[peerId];

  /// Get all peers in given state.
  List<PeerConnectionState> getPeersByState(PeerState state) =>
      _peerStates.values.where((s) => s.state == state).toList();

  /// Get all known peers.
  List<PeerConnectionState> getAllPeers() =>
      _peerStates.values.toList();

  /// Check if peer is online (discovery + TCP).
  bool isOnline(String peerId) => getState(peerId) == PeerState.online;

  /// Check if peer is transitioning (grace period).
  bool isTransitioning(String peerId) =>
      getState(peerId) == PeerState.transitioning;

  /// Check if peer is offline.
  bool isOffline(String peerId) =>
      getState(peerId) == PeerState.offline ||
      getState(peerId) == PeerState.stale;

  /// Notify tracker that peer successfully connected via TCP.
  /// 
  /// Call from connection_service when new TCP connection established.
  void markTcpConnected(String peerId) {
    final state = _peerStates[peerId];
    if (state != null) {
      state.tcpConnected = true;
      state.reconnectAttempts = 0;
      // Don't change peer state here - let discovery update it
      notifyListeners();
    }
  }

  /// Increment reconnection attempt counter.
  /// 
  /// Use for exponential backoff logic.
  void incrementReconnectAttempts(String peerId) {
    final state = _peerStates[peerId];
    if (state != null) {
      state.reconnectAttempts++;
      state.lastConnectionAttempt = DateTime.now();
    }
  }

  /// Get backoff delay for reconnection attempt.
  /// 
  /// Formula: min(base * 2^attempt, maxDelay)
  /// 0 attempts: 0ms (immediate first retry)
  /// 1 attempt: 100ms
  /// 2 attempts: 200ms
  /// 3+ attempts: 1000ms (capped)
  Duration getReconnectBackoff(String peerId) {
    final state = _peerStates[peerId];
    if (state == null) return Duration.zero;

    final attempts = state.reconnectAttempts;
    if (attempts == 0) return Duration.zero;

    final baseMs = 100;
    final delayMs = (baseMs * (1 << (attempts - 1))).clamp(0, 1000);

    return Duration(milliseconds: delayMs);
  }

  /// Cleanup and dispose resources.
  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    for (final timer in _transitionGraceTimers.values) {
      timer.cancel();
    }
    _transitionGraceTimers.clear();

    discovery.onPeersChanged = null;
    connections.onDisconnected = null;

    super.dispose();
  }

  /// Debug: print state of all peers.
  void debugPrintState() {
    if (!kDebugMode) return;

    print('[PeerTracker] State snapshot:');
    for (final entry in _peerStates.entries) {
      final state = entry.value;
      print(
        '  ${state.peer.name} (${state.peer.userId.substring(0, 8)}) '
        '→ ${state.state.name} '
        '(tcp: ${state.tcpConnected}, '
        'last_seen: ${state.lastSeen})',
      );
    }
  }
}