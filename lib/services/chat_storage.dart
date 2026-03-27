import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

class ChatStorage {
  static const _keyPrefix = 'drivechat_chat_';
  static const _readPrefix = 'drivechat_chat_read_';
  static const int _maxMessagesPerPeer = 300;

  final SharedPreferences _prefs;

  ChatStorage(this._prefs);

  static Future<ChatStorage> create() async {
    final prefs = await SharedPreferences.getInstance();
    return ChatStorage(prefs);
  }

  String _keyForPeer(String peerUserId) => '$_keyPrefix$peerUserId';
  String _readKeyForPeer(String peerUserId) => '$_readPrefix$peerUserId';

  Future<void> clearPeer(String peerUserId) async {
    await _prefs.remove(_keyForPeer(peerUserId));
    await _prefs.remove(_readKeyForPeer(peerUserId));
  }

  Future<void> clearAll() async {
    final keys = _prefs.getKeys().toList();
    for (final k in keys) {
      if (k.startsWith(_keyPrefix) || k.startsWith(_readPrefix)) {
        await _prefs.remove(k);
      }
    }
  }

  List<ChatMessage> loadMessages(String peerUserId) {
    final raw = _prefs.getString(_keyForPeer(peerUserId));
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
    } catch (_) {
      return const [];
    }
  }

  Future<void> appendMessage(String peerUserId, ChatMessage message) async {
    final existing = loadMessages(peerUserId).toList();
    existing.add(message);

    if (existing.length > _maxMessagesPerPeer) {
      final start = existing.length - _maxMessagesPerPeer;
      existing.removeRange(0, start);
    }

    final encoded = jsonEncode(existing.map((m) => m.toJson()).toList());
    await _prefs.setString(_keyForPeer(peerUserId), encoded);
  }

  int getLastReadAtMs(String peerUserId) {
    return _prefs.getInt(_readKeyForPeer(peerUserId)) ?? 0;
  }

  Future<void> setLastReadAtMs(String peerUserId, int tsMs) async {
    await _prefs.setInt(_readKeyForPeer(peerUserId), tsMs);
  }

  int getUnreadCount(String peerUserId) {
    final lastRead = getLastReadAtMs(peerUserId);
    final messages = loadMessages(peerUserId);
    var unread = 0;
    for (final m in messages) {
      if (!m.isMine && m.sentAtMs > lastRead) unread++;
    }
    return unread;
  }
}

