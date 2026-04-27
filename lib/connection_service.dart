import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'device.dart';

typedef GlobalJsonSender =
    bool Function(String peerId, Map<String, dynamic> json);
typedef GlobalJsonConnector = Future<bool> Function(String peerId);

/// Chat TCP stream — behavior matches [MsgStream] in `netstreamer.cpp`:
/// - The socket closing or failing is the single source of truth for “connection
///   lost” (no separate “internet” probe; LAN reachability is implicit in TCP).
/// - Upper layers should treat [onDisconnected] like Qt’s `connectionLost(&peerId)`.
/// - [stop]/[disconnect] close the socket; [onDone]/[onError] on the listener
///   then run and clear state the same way as a remote hang-up.
class ConnectionService {
  static const int tcpPort = 4041;

  /// Application-level liveness: send [ping] this often; drop TCP if no [pong].
  static const Duration heartbeatInterval = Duration(seconds: 30);
  static const Duration pingTimeout = Duration(seconds: 10);

  final DeviceInfo me;
  ServerSocket? _server;

  final Map<String, Socket> _sockets = {};
  final Map<String, StringBuffer> _buffers = {};

  final Uuid _uuid = const Uuid();
  Timer? _heartbeatTimer;
  final Map<String, Timer> _pingTimeoutTimers = {};
  final Map<String, String> _pendingPingIds = {};

  void Function(String peerId, Map<String, dynamic> json)? onMessage;
  void Function(String peerId)? onDisconnected;
  void Function(Socket socket, String peerId)? onIncomingConnection;
  bool Function(String peerId)? hasGlobalJsonTransport;
  GlobalJsonSender? sendGlobalJson;
  GlobalJsonConnector? connectGlobalJson;

  /// Additional observers (e.g. [HomeScreen]) without replacing [onDisconnected].
  final StreamController<String> _disconnectEvents =
      StreamController<String>.broadcast();

  /// Fired for every chat TCP loss / local [disconnect] — use for fast list refresh.
  Stream<String> get disconnectedPeerEvents => _disconnectEvents.stream;

  void _notifyDisconnected(String peerId) {
    onDisconnected?.call(peerId);
    if (!_disconnectEvents.isClosed) _disconnectEvents.add(peerId);
  }

  ConnectionService({required this.me});

  Future<Socket> _connectChatSocket(String host, int port) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) {
      throw const SocketException('Empty peer address');
    }
    final addr = InternetAddress.tryParse(trimmed);
    if (addr != null) {
      return Socket.connect(addr, port, timeout: const Duration(seconds: 8));
    }
    return Socket.connect(trimmed, port, timeout: const Duration(seconds: 8));
  }

  Future<void> startServer() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
    _server!.listen(_handleIncoming);
    _startHeartbeat();
  }

  void _clearPingState(String peerId) {
    _pingTimeoutTimers.remove(peerId)?.cancel();
    _pendingPingIds.remove(peerId);
  }

  void _stopAllPingTimers() {
    for (final t in _pingTimeoutTimers.values) {
      t.cancel();
    }
    _pingTimeoutTimers.clear();
    _pendingPingIds.clear();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      heartbeatInterval,
      (_) => _heartbeatTick(),
    );
  }

  void _heartbeatTick() {
    for (final peerId in List<String>.from(_sockets.keys)) {
      _sendPing(peerId);
    }
  }

  void _sendPing(String peerId) {
    if (!_sockets.containsKey(peerId)) return;
    final pingId = _uuid.v4();
    _pingTimeoutTimers[peerId]?.cancel();
    _pendingPingIds[peerId] = pingId;
    final ok = sendJson(peerId, {'type': 'ping', 'id': pingId});
    if (!ok) {
      unawaited(disconnect(peerId));
      return;
    }
    _pingTimeoutTimers[peerId] = Timer(pingTimeout, () {
      if (_pendingPingIds[peerId] != pingId) return;
      unawaited(disconnect(peerId));
    });
  }

  /// Reply to a peer's [ping] with matching [pingId].
  void handleIncomingPing(String peerId, String pingId) {
    sendJson(peerId, {'type': 'pong', 'id': pingId});
  }

  void handlePong(String peerId, String pingId) {
    if (_pendingPingIds[peerId] != pingId) return;
    _clearPingState(peerId);
  }

  void _handleIncoming(Socket socket) {
    _attachSocket(socket, null);
  }

  Future<Socket?> connectTo(PeerDevice peer, {bool forceNew = false}) async {
    if (peer.ip.trim().isEmpty) {
      unawaited(connectGlobalJson?.call(peer.userId));
      return null;
    }

    if (forceNew && _sockets.containsKey(peer.userId)) {
      await disconnect(peer.userId);
    }

    final existing = _sockets[peer.userId];
    if (existing != null) return existing;

    try {
      final socket = await _connectChatSocket(peer.ip, peer.port);

      _attachSocket(socket, peer.userId);

      sendJson(peer.userId, {
        'type': 'hello',
        'id': me.userId,
        'name': me.displayName,
      });
      return socket;
    } catch (_) {
      unawaited(connectGlobalJson?.call(peer.userId));
      return null;
    }
  }

  void _attachSocket(Socket socket, String? knownPeerId) {
    String? peerId = knownPeerId;
    final buf = StringBuffer();

    socket.listen(
      (data) {
        buf.write(utf8.decode(data, allowMalformed: true));
        _processBuffer(buf, peerId, (resolvedId, json) {
          if (peerId == null && resolvedId != null) {
            peerId = resolvedId;
            _sockets[resolvedId] = socket;
            _buffers[resolvedId] = buf;
            onIncomingConnection?.call(socket, resolvedId);
          }
          if (peerId != null) {
            onMessage?.call(peerId!, json);
          }
        });
      },
      onDone: () {
        if (peerId != null) {
          final id = peerId!;
          final had = _sockets.remove(peerId) != null;
          _buffers.remove(peerId);
          if (had) {
            _clearPingState(id);
            _notifyDisconnected(peerId!);
          }
        }
      },
      onError: (e, st) {
        if (peerId != null) {
          final id = peerId!;
          final had = _sockets.remove(peerId) != null;
          _buffers.remove(peerId);
          if (had) {
            _clearPingState(id);
            _notifyDisconnected(peerId!);
          }
        }
      },
      cancelOnError: true,
    );

    if (peerId != null) {
      _sockets[peerId!] = socket;
      _buffers[peerId!] = buf;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
  }

  void _processBuffer(
    StringBuffer buf,
    String? currentPeerId,
    void Function(String? resolvedPeerId, Map<String, dynamic> json) onParsed,
  ) {
    while (true) {
      final content = buf.toString();
      final nl = content.indexOf('\n');
      if (nl < 0) break;

      final line = content.substring(0, nl).trim();
      buf.clear();
      if (nl + 1 < content.length) {
        buf.write(content.substring(nl + 1));
      }

      if (line.isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;

        if (json['type'] == 'hello' && currentPeerId == null) {
          final id = json['id'] as String?;
          if (id != null) {
            onParsed(id, json);
            continue;
          }
        }

        onParsed(null, json);
      } catch (_) {}
    }
  }

  bool sendJson(String peerId, Map<String, dynamic> json) {
    final socket = _sockets[peerId];
    if (socket == null) return _sendGlobal(peerId, json);
    try {
      socket.write('${jsonEncode(json)}\n');
      return true;
    } catch (_) {
      _clearPingState(peerId);
      _sockets.remove(peerId);
      _buffers.remove(peerId);
      try {
        socket.destroy();
      } catch (_) {}
      _notifyDisconnected(peerId);
      return _sendGlobal(peerId, json);
    }
  }

  bool _sendGlobal(String peerId, Map<String, dynamic> json) {
    if (hasGlobalJsonTransport?.call(peerId) != true) return false;
    return sendGlobalJson?.call(peerId, json) == true;
  }

  Socket? getSocket(String peerId) => _sockets[peerId];
  bool isLanConnected(String peerId) => _sockets.containsKey(peerId);
  bool isConnected(String peerId) =>
      isLanConnected(peerId) || hasGlobalJsonTransport?.call(peerId) == true;
  bool isFileTransferAvailable(String peerId) => isLanConnected(peerId);

  /// At least one active chat TCP session (used for Android background wake hint).
  bool get hasActiveTcpPeers => _sockets.isNotEmpty;

  Future<void> disconnect(String peerId) async {
    _clearPingState(peerId);
    final s = _sockets.remove(peerId);
    _buffers.remove(peerId);
    try {
      await s?.close();
    } catch (_) {}
    // Socket was removed before close(); onDone may not fire with a mapped
    // peer — notify explicitly so UI and discovery stay in sync.
    if (s != null) _notifyDisconnected(peerId);
  }

  /// Closes every outbound/inbound chat socket (e.g. Wi‑Fi lost). Invokes
  /// [onDisconnected] for each so chat screens clear “connected” state.
  Future<void> disconnectAllPeers() async {
    final ids = List<String>.from(_sockets.keys);
    if (ids.isEmpty) return;
    for (final id in ids) {
      await disconnect(id);
    }
  }

  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _stopAllPingTimers();
    for (final s in _sockets.values) {
      try {
        await s.close();
      } catch (_) {}
    }
    _sockets.clear();
    _buffers.clear();
    await _server?.close();
    _server = null;
    if (!_disconnectEvents.isClosed) {
      await _disconnectEvents.close();
    }
  }
}
