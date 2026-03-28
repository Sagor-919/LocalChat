import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'message_model.dart';

class MessageStore {
  late final String _basePath;
  final Map<String, Future<void>> _locks = {};

  /// Notified after [clear] / [clearAll]; [HomeScreen] resets chat previews.
  final ValueNotifier<int> messageHistoryRevision = ValueNotifier(0);
  bool _pendingClearAll = false;
  String? _pendingClearPeerId;

  void _notifyHistoryCleared({required bool all, String? peerId}) {
    if (all) {
      _pendingClearAll = true;
      _pendingClearPeerId = null;
    } else {
      _pendingClearAll = false;
      _pendingClearPeerId = peerId;
    }
    messageHistoryRevision.value++;
  }

  /// Returns null if no clear event is pending for this revision.
  ({bool all, String? peerId})? consumePendingHistoryClear() {
    if (_pendingClearAll) {
      _pendingClearAll = false;
      _pendingClearPeerId = null;
      return (all: true, peerId: null);
    }
    final id = _pendingClearPeerId;
    if (id != null) {
      _pendingClearPeerId = null;
      return (all: false, peerId: id);
    }
    return null;
  }

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
      final appDir = Directory.systemTemp.parent.path;
      return '$appDir/files/LocalChat';
    }
    return '${Directory.systemTemp.path}/LocalChat';
  }

  Future<T> _withLock<T>(String peerId, Future<T> Function() fn) async {
    while (_locks.containsKey(peerId)) {
      try {
        await _locks[peerId];
      } catch (_) {}
    }
    final completer = Completer<void>();
    _locks[peerId] = completer.future;
    try {
      return await fn();
    } finally {
      _locks.remove(peerId);
      completer.complete();
    }
  }

  File _file(String peerId) => File('$_basePath/$peerId.json');
  File get _peersFile => File('$_basePath/_peers.json');

  static const int _defaultChatTcpPort = 4041;

  // ---------------------------------------------------------------------------
  // Peer metadata cache — persists name/ip/port so offline peers still show up
  // ---------------------------------------------------------------------------
  /// Merges with existing row so a new [name] or [ip] that is empty does not
  /// wipe a previously saved display name (e.g. from hello before discovery).
  Future<void> savePeerInfo(
      String peerId, String name, String ip, int port) async {
    final all = await _loadPeersMap();
    final prev = all[peerId];

    var resolvedName = name.trim();
    if (resolvedName.isEmpty && prev != null) {
      final p = (prev['name'] as String?)?.trim() ?? '';
      if (p.isNotEmpty) resolvedName = p;
    }
    if (resolvedName.isEmpty) resolvedName = 'Unknown';

    var resolvedIp = ip.trim();
    if (resolvedIp.isEmpty && prev != null) {
      resolvedIp = (prev['ip'] as String?)?.trim() ?? '';
    }

    var resolvedPort = port;
    if (resolvedPort <= 0 && prev != null) {
      resolvedPort = (prev['port'] as num?)?.toInt() ?? _defaultChatTcpPort;
    }
    if (resolvedPort <= 0) resolvedPort = _defaultChatTcpPort;

    all[peerId] = {
      'name': resolvedName,
      'ip': resolvedIp,
      'port': resolvedPort,
    };
    await _peersFile.writeAsString(jsonEncode(all));
  }

  Future<Map<String, Map<String, dynamic>>> loadAllPeerInfos() async {
    return _loadPeersMap();
  }

  Future<Map<String, Map<String, dynamic>>> _loadPeersMap() async {
    final f = _peersFile;
    if (!await f.exists()) return {};
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded
          .map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
    } catch (_) {
      return {};
    }
  }

  Future<List<String>> listPeerIds() async {
    final dir = Directory(_basePath);
    if (!await dir.exists()) return [];
    final ids = <String>[];
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = f.path.split(Platform.pathSeparator).last;
      if (name.startsWith('_') || !name.endsWith('.json')) continue;
      ids.add(name.replaceAll('.json', ''));
    }
    return ids;
  }

  /// Peers with at least one stored message (for offline chat list).
  Future<List<String>> listPeerIdsWithConversation() async {
    final ids = await listPeerIds();
    if (ids.isEmpty) return [];
    final flags = await Future.wait(
      ids.map((id) async {
        final f = _file(id);
        if (!await f.exists()) return (id, false);
        try {
          // Empty history is stored as `[]` — skip full read/decode.
          if (await f.length() <= 2) return (id, false);
        } catch (_) {
          return (id, false);
        }
        return (id, (await load(id)).isNotEmpty);
      }),
    );
    return [for (final p in flags) if (p.$2) p.$1];
  }

  Future<List<ChatMessage>> load(String peerId) async {
    return _withLock(peerId, () async {
      final f = _file(peerId);
      if (!await f.exists()) return <ChatMessage>[];
      try {
        final raw = await f.readAsString();
        final list = jsonDecode(raw) as List;
        return list
            .map((e) => ChatMessage.fromStore(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        return <ChatMessage>[];
      }
    });
  }

  /// Persists [msg]. Optionally updates peer display row when any of
  /// [peerDisplayName] / [peerIp] / [peerTcpPort] hints are provided.
  Future<void> add(
    String peerId,
    ChatMessage msg, {
    String? peerDisplayName,
    String? peerIp,
    int? peerTcpPort,
  }) async {
    await _withLock(peerId, () async {
      final messages = await _loadRawUnsafe(peerId);
      if (messages.any((m) => m['id'] == msg.id)) return;
      messages.add(msg.toStore());
      await _file(peerId).writeAsString(jsonEncode(messages));
    });

    final hasName = peerDisplayName != null && peerDisplayName.trim().isNotEmpty;
    final hasIp = peerIp != null && peerIp.trim().isNotEmpty;
    final hasPort = peerTcpPort != null && peerTcpPort > 0;
    if (hasName || hasIp || hasPort) {
      await savePeerInfo(
        peerId,
        peerDisplayName ?? '',
        peerIp ?? '',
        peerTcpPort ?? _defaultChatTcpPort,
      );
    }
  }

  Future<void> updateAttachmentPath(
      String peerId, String messageId, String path) async {
    return _withLock(peerId, () async {
      final messages = await _loadRawUnsafe(peerId);
      for (final m in messages) {
        if (m['id'] == messageId) {
          m['attachmentPath'] = path;
          break;
        }
      }
      await _file(peerId).writeAsString(jsonEncode(messages));
    });
  }

  Future<void> updateTransferDismissed(
      String peerId, String messageId) async {
    return _withLock(peerId, () async {
      final messages = await _loadRawUnsafe(peerId);
      for (final m in messages) {
        if (m['id'] == messageId) {
          m['transferDismissed'] = true;
          break;
        }
      }
      await _file(peerId).writeAsString(jsonEncode(messages));
    });
  }

  Future<List<Map<String, dynamic>>> _loadRawUnsafe(String peerId) async {
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
    return _withLock(peerId, () async {
      final f = _file(peerId);
      if (await f.exists()) await f.delete();
      _notifyHistoryCleared(all: false, peerId: peerId);
    });
  }

  Future<void> clearAll() async {
    final dir = Directory(_basePath);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is File) await f.delete();
      }
    }
    _notifyHistoryCleared(all: true);
  }

  Future<void> removePeerInfo(String peerId) async {
    final all = await _loadPeersMap();
    if (all.remove(peerId) != null) {
      await _peersFile.writeAsString(jsonEncode(all));
    }
  }
}
