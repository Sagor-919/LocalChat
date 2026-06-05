import 'dart:async';

import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'transfer_manager.dart';
import 'client_platform.dart';

/// Dispatches chat JSON protocol messages (QA item 25).
class ChatProtocolHandler {
  ChatProtocolHandler({
    required this.me,
    required this.connections,
    required this.discovery,
    required this.store,
    required this.discoveryPeerById,
    required this.onIncomingPlainMessage,
    required this.onIncomingEncryptedMessage,
  });

  final DeviceInfo me;
  final ConnectionService connections;
  final DiscoveryService discovery;
  final MessageStore store;
  final PeerDevice? Function(String peerId) discoveryPeerById;
  final Future<void> Function(String peerId, ChatMessage msg)
      onIncomingPlainMessage;
  final Future<void> Function(String peerId, Map<String, dynamic> json)
      onIncomingEncryptedMessage;

  void handle(String peerId, Map<String, dynamic> json) {
    final type = json['type'] as String?;

    if (type == 'ping') {
      final id = json['id'] as String?;
      if (id != null) connections.handleIncomingPing(peerId, id);
      return;
    }
    if (type == 'pong') {
      final id = json['id'] as String?;
      if (id != null) connections.handlePong(peerId, id);
      return;
    }

    if (type == 'hello') {
      final name = (json['name'] as String? ?? '').trim();
      final plat = (json['platform'] as String? ?? '').trim();
      if (plat.isNotEmpty) {
        discovery.updatePeerPlatform(peerId, plat);
      }
      final peer = discoveryPeerById(peerId);
      final sock = connections.getSocket(peerId);
      final ip = (peer?.ip ?? sock?.remoteAddress.address ?? '').trim();
      final port = peer?.port ?? ConnectionService.tcpPort;
      final displayName = name.isNotEmpty
          ? name
          : ((peer?.name ?? '').trim().isNotEmpty ? peer!.name : 'Peer');
      unawaited(store.savePeerInfo(
        peerId,
        displayName,
        ip,
        port,
        lanStableTag: peer?.lanStableTag,
      ));
      connections.sendJson(peerId, {
        'type': 'hello',
        'id': me.userId,
        'name': me.displayName,
        'platform': localClientPlatform,
      });
      return;
    }

    if (type == 'message_ack_confirm') return;

    if (type == 'message_ack') {
      final id = json['id'] as String?;
      if (id != null && id.isNotEmpty) {
        unawaited(_completeDeliveryHandshake(peerId, id));
      }
      return;
    }

    if (type == 'message') {
      final enc = json['enc'] == true;
      if (enc) {
        unawaited(onIncomingEncryptedMessage(peerId, json));
      } else {
        final msg = ChatMessage.fromJson(json, me.userId);
        if (msg != null) {
          unawaited(onIncomingPlainMessage(peerId, msg));
        }
      }
      return;
    }

    if (type == 'file_offer') {
      final peer = discoveryPeerById(peerId);
      final peerName = peer?.name ?? 'Peer';
      unawaited(TransferManager.instance.onIncomingFileOffer(
        peerId,
        json,
        peerDisplayName: peerName,
      ));
      return;
    }

    if (type == 'file_accept') {
      final id = json['id'] as String?;
      if (id != null && id.isNotEmpty) {
        TransferManager.instance.onFileAccept(peerId, id);
      }
      return;
    }

    if (type == 'file_reject') {
      final id = json['id'] as String?;
      if (id != null && id.isNotEmpty) {
        TransferManager.instance.onFileReject(peerId, id);
      }
      return;
    }

    if (type == 'file_notify') {
      final id = json['id'] as String?;
      if (id == null || id.isEmpty) return;
      TransferManager.instance.registerIncoming(
        peerId,
        id,
        json['name'] as String? ?? '',
        (json['size'] as num?)?.toInt() ?? 0,
        folderRoot: json['folderRoot'] as String?,
        batchMessageId: json['batchMessageId'] as String?,
        batchTotalSize: (json['batchTotalSize'] as num?)?.toInt(),
      );
      return;
    }

    if (type == 'file_control') {
      final id = json['id'] as String?;
      if (id == null || id.isEmpty) return;
      final from = json['from'] as String? ?? '';
      final pause = json['pause'] == true;
      if (pause) {
        if (from == 'sender') {
          TransferManager.instance.handleRemotePauseIncoming(id);
        } else if (from == 'receiver') {
          TransferManager.instance.handleRemotePauseOutgoing(id);
        }
      } else {
        if (from == 'receiver') {
          TransferManager.instance.handleRemoteResumeOutgoing(id);
        } else if (from == 'sender') {
          TransferManager.instance.handleRemoteResumeIncoming(id);
        }
      }
    }
  }

  Future<void> _completeDeliveryHandshake(
    String peerId,
    String messageId,
  ) async {
    final ok = connections.sendJson(peerId, {
      'type': 'message_ack_confirm',
      'id': messageId,
      'from': me.userId,
    });
    if (ok) {
      await store.updateDeliveryState(
        peerId,
        messageId,
        MessageDelivery.delivered,
      );
    } else {
      await store.updateDeliveryState(
        peerId,
        messageId,
        MessageDelivery.awaitingConfirm,
      );
    }
  }
}
