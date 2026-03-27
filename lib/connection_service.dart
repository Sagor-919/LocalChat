import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'device.dart';

class ConnectionService {
  static const int tcpPort = 4041;

  final DeviceInfo me;
  ServerSocket? _server;

  final Map<String, Socket> _sockets = {};
  final Map<String, StringBuffer> _buffers = {};

  void Function(String peerId, Map<String, dynamic> json)? onMessage;
  void Function(String peerId)? onDisconnected;
  void Function(Socket socket, String peerId)? onIncomingConnection;

  ConnectionService({required this.me});

  Future<Socket> _connectChatSocket(String host, int port) async {
    final trimmed = host.trim();
    if (trimmed.isEmpty) {
      throw const SocketException('Empty peer address');
    }
    final addr = InternetAddress.tryParse(trimmed);
    if (addr != null) {
      return Socket.connect(addr, port,
          timeout: const Duration(seconds: 8));
    }
    return Socket.connect(trimmed, port,
        timeout: const Duration(seconds: 8));
  }

  Future<void> startServer() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
    _server!.listen(_handleIncoming);
  }

  void _handleIncoming(Socket socket) {
    _attachSocket(socket, null);
  }

  Future<Socket?> connectTo(PeerDevice peer, {bool forceNew = false}) async {
    if (forceNew && _sockets.containsKey(peer.userId)) {
      await disconnect(peer.userId);
    }

    final existing = _sockets[peer.userId];
    if (existing != null) return existing;

    try {
      final socket = await _connectChatSocket(peer.ip, peer.port);

      _attachSocket(socket, peer.userId);

      sendJson(peer.userId,
          {'type': 'hello', 'id': me.userId, 'name': me.displayName});
      return socket;
    } catch (_) {
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
          final had = _sockets.remove(peerId) != null;
          _buffers.remove(peerId);
          if (had) onDisconnected?.call(peerId!);
        }
      },
      onError: (_) {
        if (peerId != null) {
          final had = _sockets.remove(peerId) != null;
          _buffers.remove(peerId);
          if (had) onDisconnected?.call(peerId!);
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
    if (socket == null) return false;
    try {
      socket.write('${jsonEncode(json)}\n');
      return true;
    } catch (_) {
      _sockets.remove(peerId);
      _buffers.remove(peerId);
      try {
        socket.destroy();
      } catch (_) {}
      onDisconnected?.call(peerId);
      return false;
    }
  }

  Socket? getSocket(String peerId) => _sockets[peerId];
  bool isConnected(String peerId) => _sockets.containsKey(peerId);

  Future<void> disconnect(String peerId) async {
    final s = _sockets.remove(peerId);
    _buffers.remove(peerId);
    try { await s?.close(); } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in _sockets.values) {
      try { await s.close(); } catch (_) {}
    }
    _sockets.clear();
    _buffers.clear();
    await _server?.close();
    _server = null;
  }
}
