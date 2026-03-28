/// Outgoing text delivery (persisted for my messages). Incoming messages use null.
enum MessageDelivery {
  delivered,
  /// Peer received (message_ack); waiting to send message_ack_confirm to peer.
  awaitingConfirm,
  pending,
  undelivered,
}

class ChatMessage {
  final String id;
  final String senderId;
  final String text;
  final int timestamp;
  final bool isMine;
  final String? attachmentName;
  final String? attachmentPath;
  final int? attachmentSize;
  /// ECDH + AES-GCM on the file socket for this attachment (sender opted in or receiver matched).
  final bool attachmentEncrypted;
  /// User dismissed a failed/cancelled transfer; show strikethrough / muted bubble.
  final bool transferDismissed;
  /// Only for [isMine] text messages; null means legacy or not applicable.
  final MessageDelivery? delivery;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.attachmentName,
    this.attachmentPath,
    this.attachmentSize,
    this.attachmentEncrypted = false,
    this.transferDismissed = false,
    this.delivery,
  });

  /// For sending over TCP (text messages only).
  Map<String, Object?> toJson() => {
        'type': 'message',
        'id': id,
        'from': senderId,
        'text': text,
        'time': timestamp,
      };

  static ChatMessage? fromJson(Map<String, dynamic> json, String myId) {
    if (json['type'] != 'message') return null;
    // Encrypted frames are decrypted in main.dart; avoid double-processing here.
    if (json['enc'] == true) return null;
    return ChatMessage(
      id: json['id'] as String? ?? '',
      senderId: json['from'] as String? ?? '',
      text: json['text'] as String? ?? '',
      timestamp: (json['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      isMine: (json['from'] as String?) == myId,
    );
  }

  /// For local persistence (all fields).
  Map<String, Object?> toStore() => {
        'id': id,
        'senderId': senderId,
        'text': text,
        'timestamp': timestamp,
        'isMine': isMine,
        'attachmentName': attachmentName,
        'attachmentPath': attachmentPath,
        'attachmentSize': attachmentSize,
        'attachmentEncrypted': attachmentEncrypted,
        'transferDismissed': transferDismissed,
        if (delivery != null) 'delivery': delivery!.name,
      };

  static MessageDelivery? _deliveryFromStore(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      for (final v in MessageDelivery.values) {
        if (v.name == raw) return v;
      }
    }
    return null;
  }

  static ChatMessage fromStore(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      text: json['text'] as String,
      timestamp: json['timestamp'] as int,
      isMine: json['isMine'] as bool,
      attachmentName: json['attachmentName'] as String?,
      attachmentPath: json['attachmentPath'] as String?,
      attachmentSize: (json['attachmentSize'] as num?)?.toInt(),
      attachmentEncrypted: json['attachmentEncrypted'] as bool? ?? false,
      transferDismissed: json['transferDismissed'] as bool? ?? false,
      delivery: _deliveryFromStore(json['delivery']),
    );
  }

  ChatMessage copyWith({
    String? id,
    String? senderId,
    String? text,
    int? timestamp,
    bool? isMine,
    String? attachmentName,
    String? attachmentPath,
    int? attachmentSize,
    bool? attachmentEncrypted,
    bool? transferDismissed,
    MessageDelivery? delivery,
    bool clearDelivery = false,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      isMine: isMine ?? this.isMine,
      attachmentName: attachmentName ?? this.attachmentName,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      attachmentSize: attachmentSize ?? this.attachmentSize,
      attachmentEncrypted: attachmentEncrypted ?? this.attachmentEncrypted,
      transferDismissed: transferDismissed ?? this.transferDismissed,
      delivery: clearDelivery ? null : (delivery ?? this.delivery),
    );
  }
}
