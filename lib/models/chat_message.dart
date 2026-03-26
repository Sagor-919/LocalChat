class ChatMessage {
  final String messageId;
  final String peerUserId;
  final String senderUserId;
  final String senderDisplayName;
  final String text;
  final int sentAtMs;
  final bool isMine;

  const ChatMessage({
    required this.messageId,
    required this.peerUserId,
    required this.senderUserId,
    required this.senderDisplayName,
    required this.text,
    required this.sentAtMs,
    required this.isMine,
  });

  DateTime get sentAt => DateTime.fromMillisecondsSinceEpoch(sentAtMs);

  Map<String, Object?> toJson() => {
        'mid': messageId,
        'peerId': peerUserId,
        'from': senderUserId,
        'fromName': senderDisplayName,
        'text': text,
        'ts': sentAtMs,
        'mine': isMine,
      };

  static ChatMessage fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      messageId: json['mid'] as String,
      peerUserId: json['peerId'] as String,
      senderUserId: json['from'] as String,
      senderDisplayName: (json['fromName'] as String?) ?? 'Unknown',
      text: json['text'] as String,
      sentAtMs: (json['ts'] as num).toInt(),
      isMine: (json['mine'] as bool?) ?? false,
    );
  }
}

