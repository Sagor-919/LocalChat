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
      default:
        throw FormatException('Unknown message type: $type');
    }
  }
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

