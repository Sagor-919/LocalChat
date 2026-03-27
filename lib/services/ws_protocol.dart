import 'dart:convert';

sealed class WsMessage {
  const WsMessage();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  static WsMessage decode(String raw) {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Invalid message: not a JSON object');
    }

    final map = decoded.cast<String, dynamic>();
    final type = map['type'];
    if (type is! String) {
      throw const FormatException('Invalid message: missing type');
    }

    switch (type) {
      case HelloMessage.typeValue:
        return HelloMessage(
          userId: map['id'] as String,
          displayName: map['name'] as String,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case HelloAckMessage.typeValue:
        return HelloAckMessage(
          userId: map['id'] as String,
          displayName: map['name'] as String,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ConnectRejectMessage.typeValue:
        return ConnectRejectMessage(
          reason: map['reason'] as String? ?? 'Rejected',
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatTypingMessage.typeValue:
        return ChatTypingMessage(
          fromUserId: map['from'] as String,
          isTyping: (map['typing'] as bool?) ?? false,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatLeaveMessage.typeValue:
        return ChatLeaveMessage(
          fromUserId: map['from'] as String,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatTextMessage.typeValue:
        return ChatTextMessage(
          messageId: map['mid'] as String,
          fromUserId: map['from'] as String,
          fromDisplayName: map['fromName'] as String? ?? 'Unknown',
          text: map['text'] as String,
          sentAtMs: (map['ts'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatFileMetaMessage.typeValue:
        return ChatFileMetaMessage(
          fileId: map['fid'] as String,
          fromUserId: map['from'] as String,
          fromDisplayName: map['fromName'] as String? ?? 'Unknown',
          fileName: map['name'] as String,
          fileSize: (map['size'] as num).toInt(),
          totalChunks: (map['total'] as num).toInt(),
          sentAtMs: (map['ts'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatFileChunkMessage.typeValue:
        return ChatFileChunkMessage(
          fileId: map['fid'] as String,
          fromUserId: map['from'] as String,
          index: (map['idx'] as num).toInt(),
          totalChunks: (map['total'] as num).toInt(),
          base64Data: map['data'] as String,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      case ChatFileCompleteMessage.typeValue:
        return ChatFileCompleteMessage(
          fileId: map['fid'] as String,
          fromUserId: map['from'] as String,
          version: (map['v'] as num?)?.toInt() ?? 1,
        );
      default:
        return UnknownMessage(type: type, payload: map);
    }
  }
}

class UnknownMessage extends WsMessage {
  final String type;
  final Map<String, Object?> payload;

  const UnknownMessage({
    required this.type,
    required this.payload,
  });

  @override
  Map<String, Object?> toJson() => payload;
}

class HelloMessage extends WsMessage {
  static const String typeValue = 'hello';
  final String userId;
  final String displayName;
  final int version;

  const HelloMessage({
    required this.userId,
    required this.displayName,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'id': userId,
        'name': displayName,
        'v': version,
      };
}

class HelloAckMessage extends WsMessage {
  static const String typeValue = 'hello_ack';
  final String userId;
  final String displayName;
  final int version;

  const HelloAckMessage({
    required this.userId,
    required this.displayName,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'id': userId,
        'name': displayName,
        'v': version,
      };
}

class ConnectRejectMessage extends WsMessage {
  static const String typeValue = 'connect_reject';
  final String reason;
  final int version;

  const ConnectRejectMessage({
    required this.reason,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'reason': reason,
        'v': version,
      };
}

class ChatTypingMessage extends WsMessage {
  static const String typeValue = 'chat_typing';
  final String fromUserId;
  final bool isTyping;
  final int version;

  const ChatTypingMessage({
    required this.fromUserId,
    required this.isTyping,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'from': fromUserId,
        'typing': isTyping,
        'v': version,
      };
}

class ChatLeaveMessage extends WsMessage {
  static const String typeValue = 'chat_leave';
  final String fromUserId;
  final int version;

  const ChatLeaveMessage({
    required this.fromUserId,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'from': fromUserId,
        'v': version,
      };
}

class ChatTextMessage extends WsMessage {
  static const String typeValue = 'chat_text';

  final String messageId;
  final String fromUserId;
  final String fromDisplayName;
  final String text;
  final int sentAtMs;
  final int version;

  const ChatTextMessage({
    required this.messageId,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.text,
    required this.sentAtMs,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'mid': messageId,
        'from': fromUserId,
        'fromName': fromDisplayName,
        'text': text,
        'ts': sentAtMs,
        'v': version,
      };
}

class ChatFileMetaMessage extends WsMessage {
  static const String typeValue = 'chat_file_meta';

  final String fileId;
  final String fromUserId;
  final String fromDisplayName;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final int sentAtMs;
  final int version;

  const ChatFileMetaMessage({
    required this.fileId,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
    required this.sentAtMs,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'fid': fileId,
        'from': fromUserId,
        'fromName': fromDisplayName,
        'name': fileName,
        'size': fileSize,
        'total': totalChunks,
        'ts': sentAtMs,
        'v': version,
      };
}

class ChatFileChunkMessage extends WsMessage {
  static const String typeValue = 'chat_file_chunk';

  final String fileId;
  final String fromUserId;
  final int index;
  final int totalChunks;
  final String base64Data;
  final int version;

  const ChatFileChunkMessage({
    required this.fileId,
    required this.fromUserId,
    required this.index,
    required this.totalChunks,
    required this.base64Data,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'fid': fileId,
        'from': fromUserId,
        'idx': index,
        'total': totalChunks,
        'data': base64Data,
        'v': version,
      };
}

class ChatFileCompleteMessage extends WsMessage {
  static const String typeValue = 'chat_file_complete';

  final String fileId;
  final String fromUserId;
  final int version;

  const ChatFileCompleteMessage({
    required this.fileId,
    required this.fromUserId,
    this.version = 1,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': typeValue,
        'fid': fileId,
        'from': fromUserId,
        'v': version,
      };
}

