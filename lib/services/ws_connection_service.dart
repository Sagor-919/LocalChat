import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/peer_device.dart';
import 'device_identity.dart';
import 'ws_protocol.dart';

enum PeerConnectionStatus {
  disconnected,
  connecting,
  connected,
  failed,
}

class PeerConnectionState {
  final PeerDevice peer;
  PeerConnectionStatus status;
  String? error;

  WebSocket? socket;

  PeerConnectionState({
    required this.peer,
    required this.status,
    this.error,
    this.socket,
  });
}

typedef ConnectionChanged = void Function(
  String peerId,
  PeerConnectionState state,
);

class WsConnectionService {
  final DeviceIdentity identity;
  final int listenPort;

  HttpServer? _server;
  final Map<String, PeerConnectionState> _connections = {};

  ConnectionChanged? onConnectionChanged;

  WsConnectionService({
    required this.identity,
    required this.listenPort,
    this.onConnectionChanged,
  });

  Future<void> startServer() async {
    if (_server != null) return;

    // Bind on all interfaces (LAN). Phase 2 wants each device to be a server too.
    final server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    _server = server;

    unawaited(_acceptLoop(server));
  }

  Future<void> _acceptLoop(HttpServer server) async {
    try {
      await for (final req in server) {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final remoteIp =
              req.connectionInfo?.remoteAddress.address ?? 'unknown';
          final ws = await WebSocketTransformer.upgrade(req);
          unawaited(_handleIncomingSocket(ws, remoteIp));
        } else {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      }
    } catch (_) {
      // Server closed.
    }
  }

  Future<void> _handleIncomingSocket(WebSocket ws, String remoteIp) async {
    // Wait for hello.
    String? peerId;
    try {
      final raw = await ws.first.timeout(const Duration(seconds: 4));
      final rawString = raw is String ? raw : utf8.decode(raw as List<int>);
      final msg = WsMessage.decode(rawString);
      if (msg case HelloMessage hello) {
        peerId = hello.userId;
        final peer = PeerDevice(
          userId: hello.userId,
          displayName: hello.displayName,
          ipAddress: remoteIp,
          wsPort: listenPort,
          lastSeen: DateTime.now(),
        );

        final state = PeerConnectionState(
          peer: peer,
          status: PeerConnectionStatus.connected,
          socket: ws,
        );
        _connections[peerId] = state;
        onConnectionChanged?.call(peerId, state);

        // Reply with ack.
        final ack = HelloAckMessage(
          userId: identity.userId,
          displayName: identity.displayName,
        );
        ws.add(ack.encode());

        // Keep listening until closed.
        await ws.done;
      } else {
        throw const FormatException('Expected hello');
      }
    } catch (e) {
      await ws.close();
      if (peerId != null) {
        final existing = _connections[peerId];
        if (existing != null) {
          existing.status = PeerConnectionStatus.disconnected;
          existing.error = e.toString();
          onConnectionChanged?.call(peerId, existing);
        }
      }
    } finally {
      if (peerId != null) {
        final existing = _connections[peerId];
        if (existing != null && existing.socket == ws) {
          existing.status = PeerConnectionStatus.disconnected;
          onConnectionChanged?.call(peerId, existing);
        }
      }
    }
  }

  PeerConnectionState? getConnection(String peerId) => _connections[peerId];

  Future<PeerConnectionState> connectToPeer(PeerDevice peer) async {
    final existing = _connections[peer.userId];
    if (existing != null &&
        existing.status == PeerConnectionStatus.connected &&
        existing.socket != null) {
      return existing;
    }

    final state = PeerConnectionState(
      peer: peer,
      status: PeerConnectionStatus.connecting,
    );
    _connections[peer.userId] = state;
    onConnectionChanged?.call(peer.userId, state);

    try {
      final ws = await WebSocket.connect('ws://${peer.ipAddress}:${peer.wsPort}')
          .timeout(const Duration(seconds: 5));

      state.socket = ws;
      final hello = HelloMessage(
        userId: identity.userId,
        displayName: identity.displayName,
      );
      ws.add(hello.encode());

      // Wait for ack.
      final raw = await ws.first.timeout(const Duration(seconds: 4));
      final rawString = raw is String ? raw : utf8.decode(raw as List<int>);
      final msg = WsMessage.decode(rawString);
      if (msg case HelloAckMessage _) {
        state.status = PeerConnectionStatus.connected;
        state.error = null;
        onConnectionChanged?.call(peer.userId, state);

        unawaited(ws.done.then((_) {
          final current = _connections[peer.userId];
          if (current != null && current.socket == ws) {
            current.status = PeerConnectionStatus.disconnected;
            onConnectionChanged?.call(peer.userId, current);
          }
        }));

        return state;
      }

      throw const FormatException('Expected hello_ack');
    } catch (e) {
      state.status = PeerConnectionStatus.failed;
      state.error = e.toString();
      onConnectionChanged?.call(peer.userId, state);
      return state;
    }
  }

  Future<void> stopServer() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> close() async {
    for (final entry in _connections.values) {
      try {
        await entry.socket?.close();
      } catch (_) {}
    }
    _connections.clear();
    await stopServer();
  }
}

