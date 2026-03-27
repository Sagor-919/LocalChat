class ChatMessage {
  final String id;
  final String senderId;
  final String text;
  final int timestamp;
  final bool isMine;
  final String? attachmentName;
  final String? attachmentPath;

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.attachmentName,
    this.attachmentPath,
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
      };

  static ChatMessage fromStore(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      text: json['text'] as String,
      timestamp: json['timestamp'] as int,
      isMine: json['isMine'] as bool,
      attachmentName: json['attachmentName'] as String?,
      attachmentPath: json['attachmentPath'] as String?,
    );
  }
}
