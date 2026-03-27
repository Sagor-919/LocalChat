import 'dart:convert';
import 'dart:io';

import 'message_model.dart';

class MessageStore {
  late final String _basePath;

  MessageStore._();

  static Future<MessageStore> init() async {
    final store = MessageStore._();
    store._basePath = '${await _resolveDataDir()}/localchat_messages';
    await Directory(store._basePath).create(recursive: true);
    return store;
  }

  static Future<String> _resolveDataDir() async {
    if (Platform.isWindows) {
      final dir = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'];
      if (dir != null) return '$dir/LocalChat';
    }
    if (Platform.isAndroid) {
      // On Android, Directory.systemTemp is <app_data>/cache.
      // Go up one level to get the app data root, then use /files.
      final appDir = Directory.systemTemp.parent.path;
      return '$appDir/files/LocalChat';
    }
    return '${Directory.systemTemp.path}/LocalChat';
  }

  File _file(String peerId) => File('$_basePath/$peerId.json');

  Future<List<ChatMessage>> load(String peerId) async {
    final f = _file(peerId);
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ChatMessage.fromStore(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> add(String peerId, ChatMessage msg) async {
    final messages = await _loadRaw(peerId);
    if (messages.any((m) => m['id'] == msg.id)) return;
    messages.add(msg.toStore());
    await _file(peerId).writeAsString(jsonEncode(messages));
  }

  Future<void> updateAttachmentPath(
      String peerId, String messageId, String path) async {
    final messages = await _loadRaw(peerId);
    for (final m in messages) {
      if (m['id'] == messageId) {
        m['attachmentPath'] = path;
        break;
      }
    }
    await _file(peerId).writeAsString(jsonEncode(messages));
  }

  Future<List<Map<String, dynamic>>> _loadRaw(String peerId) async {
    final f = _file(peerId);
    if (!await f.exists()) return [];
    try {
      final raw = await f.readAsString();
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> clear(String peerId) async {
    final f = _file(peerId);
    if (await f.exists()) await f.delete();
  }

  Future<void> clearAll() async {
    final dir = Directory(_basePath);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is File) await f.delete();
      }
    }
  }
}
