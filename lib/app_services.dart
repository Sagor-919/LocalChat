import 'dart:async';

import 'package:flutter/material.dart';

import 'models/chat_message.dart';
import 'models/peer_device.dart';
import 'services/chat_storage.dart';
import 'services/device_identity.dart';
import 'services/mdns_presence_service.dart';
import 'services/notification_service.dart';
import 'services/ws_connection_service.dart';
import 'services/ws_protocol.dart';
import 'screens/chat_screen.dart';

class AppServices {
  static const int kWebSocketPort = 4040;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  DeviceIdentityRepository? _identityRepo;
  DeviceIdentity? identity;
  MdnsPresenceService? presence;
  WsConnectionService? connections;
  ChatStorage? chatStorage;
  final NotificationService notifications = NotificationService();

  bool isInForeground = true;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _identityRepo = await DeviceIdentityRepository.create();
    identity = await _identityRepo!.loadOrCreate();
    chatStorage = await ChatStorage.create();

    connections = WsConnectionService(
      identity: identity!,
      listenPort: kWebSocketPort,
    );
    await connections!.startServer();

    presence = MdnsPresenceService(
      identity: identity!,
      websocketPort: kWebSocketPort,
    );
    try {
      await presence!.startAdvertising();
    } catch (_) {
      // Advertising is best-effort.
    }

    // Default message handler: persist + maybe notify.
    connections!.onMessageReceived = (peerId, msg) {
      if (msg is! ChatTextMessage) return;
      final peer = connections!.getConnection(peerId)?.peer;
      if (peer == null) return;

      final chat = ChatMessage(
        messageId: msg.messageId,
        peerUserId: peer.userId,
        senderUserId: msg.fromUserId,
        senderDisplayName: msg.fromDisplayName,
        text: msg.text,
        sentAtMs: msg.sentAtMs,
        isMine: msg.fromUserId == identity!.userId,
      );
      unawaited(chatStorage?.appendMessage(peer.userId, chat));

      if (!isInForeground) {
        unawaited(
          notifications.showIncomingMessage(
            peer: peer,
            message: msg.text,
          ),
        );
      }
    };

    await notifications.initialize();
    notifications.onTapPeer = (peer) {
      unawaited(openChatWithPeer(peer, connectIfNeeded: true));
    };
  }

  Future<void> openChatWithPeer(PeerDevice peer,
      {required bool connectIfNeeded}) async {
    final nav = navigatorKey.currentState;
    final me = identity;
    final conn = connections;
    if (nav == null || me == null || conn == null) return;

    if (connectIfNeeded) {
      await conn.connectToPeer(peer);
    }

    await nav.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          me: me,
          peer: peer,
          connections: conn,
        ),
      ),
    );
  }

  Future<void> setDisplayName(String displayName) async {
    final repo = _identityRepo;
    if (repo == null) return;
    final name = displayName.trim();
    if (name.isEmpty) return;

    await repo.setDisplayName(name);
    identity = await repo.loadOrCreate();

    // Restart mDNS advertising to update TXT record values.
    try {
      await presence?.stopAdvertising();
    } catch (_) {}
    presence = MdnsPresenceService(
      identity: identity!,
      websocketPort: kWebSocketPort,
    );
    try {
      await presence!.startAdvertising();
    } catch (_) {}
  }

  Future<void> stop() async {
    await presence?.close();
    await connections?.close();
  }
}

