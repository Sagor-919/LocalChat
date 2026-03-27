import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/peer_device.dart';
import 'device_identity.dart';
import 'ws_protocol.dart';

enum PeerConnectionStatus {
  disconnected,
  connecting,
  incomingRequest,
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

typedef MessageReceived = void Function(
  String peerId,
  WsMessage message,
);

typedef IncomingConnectionRequested = void Function(
  String peerId,
  PeerConnectionState state,
);

class WsConnectionService {
  final DeviceIdentity identity;
  final int listenPort;
  late final int fileTransferPort;
  final Uuid _uuid = const Uuid();

  HttpServer? _server;
  ServerSocket? _fileServer;
  final Map<String, PeerConnectionState> _connections = {};
  final Map<String, StreamSubscription> _socketSubscriptions = {};
  final Map<String, Completer<bool>> _incomingDecisions = {};

  ConnectionChanged? onConnectionChanged;
  MessageReceived? onMessageReceived;
  IncomingConnectionRequested? onIncomingConnectionRequested;

  /// Raw TCP socket callback — the receiver (chat screen) handles header
  /// reading and data streaming itself via FileReceiver.
  void Function(Socket socket)? onIncomingFileSocket;

  WsConnectionService({
    required this.identity,
    required this.listenPort,
    this.onConnectionChanged,
    this.onMessageReceived,
    this.onIncomingConnectionRequested,
    this.onIncomingFileSocket,
  }) {
    fileTransferPort = listenPort + 1;
  }

  // -------------------------------------------------------------------------
  // Server start
  // -------------------------------------------------------------------------
  Future<void> startServer() async {
    if (_server != null) return;

    final server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    _server = server;

    unawaited(_acceptLoop(server));
    _fileServer =
        await ServerSocket.bind(InternetAddress.anyIPv4, fileTransferPort);
    unawaited(_acceptFileLoop(_fileServer!));
  }

  // -------------------------------------------------------------------------
  // TCP file server — just accept and pass through
  // -------------------------------------------------------------------------
  Future<void> _acceptFileLoop(ServerSocket server) async {
    try {
      await for (final socket in server) {
        final cb = onIncomingFileSocket;
        if (cb != null) {
          cb(socket);
        } else {
          socket.close();
        }
      }
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // WS accept loop
  // -------------------------------------------------------------------------
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
    } catch (_) {}
  }

  Future<void> _handleIncomingSocket(WebSocket ws, String remoteIp) async {
    String? peerId;
    try {
      final stream = ws.asBroadcastStream();
      final raw = await stream.first.timeout(const Duration(seconds: 4));
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
          status: PeerConnectionStatus.incomingRequest,
          socket: ws,
        );
        _connections[peerId] = state;
        onConnectionChanged?.call(peerId, state);
        onIncomingConnectionRequested?.call(peerId, state);

        final decision = Completer<bool>();
        _incomingDecisions[peerId] = decision;

        final accepted = await decision.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => false,
        );
        _incomingDecisions.remove(peerId);

        if (!accepted) {
          try {
            ws.add(const ConnectRejectMessage(reason: 'Declined').encode());
          } catch (_) {}
          await ws.close();
          state.status = PeerConnectionStatus.disconnected;
          onConnectionChanged?.call(peerId, state);
          return;
        }

        final ack = HelloAckMessage(
          userId: identity.userId,
          displayName: identity.displayName,
        );
        ws.add(ack.encode());

        state.status = PeerConnectionStatus.connected;
        state.error = null;
        onConnectionChanged?.call(peerId, state);

        _attachMessageListener(peerId, stream);
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

  bool acceptIncoming(String peerId) {
    final c = _incomingDecisions[peerId];
    if (c == null || c.isCompleted) return false;
    c.complete(true);
    return true;
  }

  bool rejectIncoming(String peerId) {
    final c = _incomingDecisions[peerId];
    if (c == null || c.isCompleted) return false;
    c.complete(false);
    return true;
  }

  void _attachMessageListener(String peerId, Stream<dynamic> stream) {
    _socketSubscriptions[peerId]?.cancel();
    _socketSubscriptions[peerId] = stream.listen(
      (raw) {
        try {
          final rawString =
              raw is String ? raw : utf8.decode(raw as List<int>);
          final msg = WsMessage.decode(rawString);
          if (msg is HelloMessage || msg is HelloAckMessage) return;
          onMessageReceived?.call(peerId, msg);
        } catch (_) {}
      },
      onDone: () { _socketSubscriptions.remove(peerId)?.cancel(); },
      onError: (_) { _socketSubscriptions.remove(peerId)?.cancel(); },
      cancelOnError: true,
    );
  }

  // -------------------------------------------------------------------------
  // Connect to peer
  // -------------------------------------------------------------------------
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
      final ws =
          await WebSocket.connect('ws://${peer.ipAddress}:${peer.wsPort}')
              .timeout(const Duration(seconds: 5));
      final stream = ws.asBroadcastStream();

      state.socket = ws;
      final hello = HelloMessage(
        userId: identity.userId,
        displayName: identity.displayName,
      );
      ws.add(hello.encode());

      final raw = await stream.first.timeout(const Duration(seconds: 4));
      final rawString = raw is String ? raw : utf8.decode(raw as List<int>);
      final msg = WsMessage.decode(rawString);
      if (msg case HelloAckMessage _) {
        state.status = PeerConnectionStatus.connected;
        state.error = null;
        onConnectionChanged?.call(peer.userId, state);

        _attachMessageListener(peer.userId, stream);

        unawaited(ws.done.then((_) {
          final current = _connections[peer.userId];
          if (current != null && current.socket == ws) {
            current.status = PeerConnectionStatus.disconnected;
            onConnectionChanged?.call(peer.userId, current);
          }
        }));

        return state;
      }

      if (msg case ConnectRejectMessage rej) {
        throw FormatException(rej.reason);
      }

      throw const FormatException('Expected hello_ack or connect_reject');
    } catch (e) {
      state.status = PeerConnectionStatus.failed;
      state.error = e.toString();
      onConnectionChanged?.call(peer.userId, state);
      return state;
    }
  }

  // -------------------------------------------------------------------------
  // WS message helpers
  // -------------------------------------------------------------------------
  ChatTextMessage? sendChatText(String peerId, String text) {
    final state = _connections[peerId];
    final ws = state?.socket;
    if (state == null ||
        ws == null ||
        state.status != PeerConnectionStatus.connected ||
        ws.closeCode != null) {
      return null;
    }

    final msg = ChatTextMessage(
      messageId: _uuid.v4(),
      fromUserId: identity.userId,
      fromDisplayName: identity.displayName,
      text: text,
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      ws.add(msg.encode());
      return msg;
    } catch (e) {
      state.status = PeerConnectionStatus.disconnected;
      state.error = e.toString();
      onConnectionChanged?.call(peerId, state);
      return null;
    }
  }

  bool sendWsMessage(String peerId, WsMessage msg) {
    final state = _connections[peerId];
    final ws = state?.socket;
    if (state == null ||
        ws == null ||
        state.status != PeerConnectionStatus.connected ||
        ws.closeCode != null) {
      return false;
    }

    try {
      ws.add(msg.encode());
      return true;
    } catch (e) {
      state.status = PeerConnectionStatus.disconnected;
      state.error = e.toString();
      onConnectionChanged?.call(peerId, state);
      return false;
    }
  }

  bool sendTyping(String peerId, {required bool isTyping}) {
    final state = _connections[peerId];
    final ws = state?.socket;
    if (state == null ||
        ws == null ||
        state.status != PeerConnectionStatus.connected ||
        ws.closeCode != null) {
      return false;
    }

    try {
      ws.add(ChatTypingMessage(
        fromUserId: identity.userId,
        isTyping: isTyping,
      ).encode());
      return true;
    } catch (_) {
      state.status = PeerConnectionStatus.disconnected;
      onConnectionChanged?.call(peerId, state);
      return false;
    }
  }

  bool sendLeaveChat(String peerId) {
    final state = _connections[peerId];
    final ws = state?.socket;
    if (state == null ||
        ws == null ||
        state.status != PeerConnectionStatus.connected ||
        ws.closeCode != null) {
      return false;
    }

    try {
      ws.add(ChatLeaveMessage(fromUserId: identity.userId).encode());
      return true;
    } catch (_) {
      state.status = PeerConnectionStatus.disconnected;
      onConnectionChanged?.call(peerId, state);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------
  Future<void> stopServer() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    final fileServer = _fileServer;
    _fileServer = null;
    await fileServer?.close();
  }

  Future<void> close() async {
    for (final entry in _connections.values) {
      try { await entry.socket?.close(); } catch (_) {}
    }
    for (final sub in _socketSubscriptions.values) {
      try { await sub.cancel(); } catch (_) {}
    }
    _socketSubscriptions.clear();
    _connections.clear();
    await stopServer();
  }
}
