import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'message_model.dart';
import 'sqflite_init.dart';

class MessageStore {
  late final String _dataDir;
  late Database _db;

  /// Absolute directory containing `localchat.db` (e.g. Windows: `%LOCALAPPDATA%\LocalChat`).
  String get dataDirectoryPath => _dataDir;

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

  static const int _dbVersion = 2;
  static const int _defaultChatTcpPort = 4041;

  static Future<MessageStore> init() async {
    await ensureSqfliteInitialized();
    final store = MessageStore._();
    store._dataDir = await _resolveDataDir();
    await Directory(store._dataDir).create(recursive: true);

    final dbPath = p.join(store._dataDir, 'localchat.db');
    store._db = await openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE peers ADD COLUMN lan_stable_tag TEXT');
        }
      },
    );
    await store._migrateFromLegacyJsonIfNeeded();
    return store;
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE peers (
        peer_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        ip TEXT NOT NULL,
        port INTEGER NOT NULL,
        lan_stable_tag TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        peer_id TEXT NOT NULL,
        id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_mine INTEGER NOT NULL,
        attachment_name TEXT,
        attachment_path TEXT,
        attachment_size INTEGER,
        transfer_dismissed INTEGER NOT NULL DEFAULT 0,
        delivery TEXT,
        PRIMARY KEY (peer_id, id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_peer_time ON messages(peer_id, timestamp)',
    );
  }

  /// One-time import from `localchat_messages/*.json` and `_peers.json`.
  Future<void> _migrateFromLegacyJsonIfNeeded() async {
    final legacyDir = Directory(p.join(_dataDir, 'localchat_messages'));
    if (!await legacyDir.exists()) return;

    final peersCount = Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM peers'),
    );
    final peersFile = File(p.join(legacyDir.path, '_peers.json'));
    if ((peersCount == null || peersCount == 0) && await peersFile.exists()) {
      try {
        final raw = await peersFile.readAsString();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final batch = _db.batch();
        for (final e in map.entries) {
          final id = e.key;
          final v = e.value as Map<String, dynamic>;
          batch.insert(
            'peers',
            {
              'peer_id': id,
              'name': v['name'] as String? ?? 'Unknown',
              'ip': v['ip'] as String? ?? '',
              'port': (v['port'] as num?)?.toInt() ?? _defaultChatTcpPort,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        try {
          await peersFile.delete();
        } catch (_) {}
      } catch (_) {}
    }

    final msgCount = Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM messages'),
    );
    if (msgCount != null && msgCount > 0) return;

    try {
      await for (final entity in legacyDir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.json') || name.startsWith('_')) continue;
        final peerId = name.replaceAll('.json', '');
        if (peerId.isEmpty) continue;

        final raw = await entity.readAsString();
        final list = jsonDecode(raw) as List;
        final batch = _db.batch();
        for (final item in list) {
          final m = item as Map<String, dynamic>;
          batch.insert(
            'messages',
            _messageMapFromLegacyJson(peerId, m),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
      await _deleteLegacyJsonFiles(legacyDir);
    } catch (_) {}
  }

  Future<void> _deleteLegacyJsonFiles(Directory legacyDir) async {
    try {
      await for (final entity in legacyDir.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
      try {
        await legacyDir.delete();
      } catch (_) {}
    } catch (_) {}
  }

  static Map<String, Object?> _messageMapFromLegacyJson(
    String peerId,
    Map<String, dynamic> m,
  ) {
    return {
      'peer_id': peerId,
      'id': m['id'] as String,
      'sender_id': m['senderId'] as String,
      'text': m['text'] as String,
      'timestamp': m['timestamp'] as int,
      'is_mine': (m['isMine'] as bool?) == true ? 1 : 0,
      'attachment_name': m['attachmentName'] as String?,
      'attachment_path': m['attachmentPath'] as String?,
      'attachment_size': (m['attachmentSize'] as num?)?.toInt(),
      'transfer_dismissed': (m['transferDismissed'] as bool?) == true ? 1 : 0,
      'delivery': m['delivery'] as String?,
    };
  }

  static Map<String, Object?> _messageToRow(String peerId, ChatMessage msg) {
    return {
      'peer_id': peerId,
      'id': msg.id,
      'sender_id': msg.senderId,
      'text': msg.text,
      'timestamp': msg.timestamp,
      'is_mine': msg.isMine ? 1 : 0,
      'attachment_name': msg.attachmentName,
      'attachment_path': msg.attachmentPath,
      'attachment_size': msg.attachmentSize,
      'transfer_dismissed': msg.transferDismissed ? 1 : 0,
      'delivery': msg.delivery?.name,
    };
  }

  static ChatMessage _rowToMessage(Map<String, Object?> row) {
    return ChatMessage.fromStore({
      'id': row['id'] as String,
      'senderId': row['sender_id'] as String,
      'text': row['text'] as String,
      'timestamp': row['timestamp'] as int,
      'isMine': (row['is_mine'] as int) != 0,
      'attachmentName': row['attachment_name'] as String?,
      'attachmentPath': row['attachment_path'] as String?,
      'attachmentSize': (row['attachment_size'] as int?),
      'transferDismissed': (row['transfer_dismissed'] as int? ?? 0) != 0,
      'delivery': row['delivery'] as String?,
    });
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

  // ---------------------------------------------------------------------------
  // Peer metadata
  // ---------------------------------------------------------------------------
  Future<void> savePeerInfo(
    String peerId,
    String name,
    String ip,
    int port, {
    String? lanStableTag,
  }) async {
    final all = await loadAllPeerInfos();
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

    var resolvedTag = lanStableTag?.trim();
    if (resolvedTag == null || resolvedTag.isEmpty) {
      final prevRow = await _db.query(
        'peers',
        columns: ['lan_stable_tag'],
        where: 'peer_id = ?',
        whereArgs: [peerId],
        limit: 1,
      );
      if (prevRow.isNotEmpty) {
        resolvedTag = prevRow.first['lan_stable_tag'] as String?;
      }
    }

    await _db.insert(
      'peers',
      {
        'peer_id': peerId,
        'name': resolvedName,
        'ip': resolvedIp,
        'port': resolvedPort,
        'lan_stable_tag': resolvedTag,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Peers whose stored [lan_stable_tag] matches [tag] but id is not [exceptPeerId].
  Future<List<String>> peerIdsMatchingLanTag(
    String tag,
    String exceptPeerId,
  ) async {
    final t = tag.trim();
    if (t.isEmpty) return [];
    final rows = await _db.query(
      'peers',
      columns: ['peer_id'],
      where: 'lan_stable_tag = ? AND peer_id != ?',
      whereArgs: [t, exceptPeerId],
    );
    return [for (final r in rows) r['peer_id'] as String];
  }

  /// Rewrites history when a neighbor keeps the same device but gets a new UUID.
  Future<void> mergePeerLanIdentity({
    required String fromPeerId,
    required String toPeerId,
    required String name,
    required String ip,
    required int port,
    String? lanStableTag,
  }) async {
    if (fromPeerId == toPeerId) return;
    await _db.transaction((txn) async {
      await txn.update(
        'messages',
        {'peer_id': toPeerId},
        where: 'peer_id = ?',
        whereArgs: [fromPeerId],
      );
      await txn.update(
        'messages',
        {'sender_id': toPeerId},
        where: 'peer_id = ? AND sender_id = ?',
        whereArgs: [toPeerId, fromPeerId],
      );
      await txn.delete('peers', where: 'peer_id = ?', whereArgs: [fromPeerId]);
      final tag = lanStableTag?.trim();
      await txn.insert(
        'peers',
        {
          'peer_id': toPeerId,
          'name': name,
          'ip': ip,
          'port': port,
          if (tag != null && tag.isNotEmpty) 'lan_stable_tag': tag,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    messageHistoryRevision.value++;
  }

  Future<Map<String, Map<String, dynamic>>> loadAllPeerInfos() async {
    final rows = await _db.query('peers');
    return {
      for (final r in rows)
        r['peer_id'] as String: {
          'name': r['name'],
          'ip': r['ip'],
          'port': r['port'],
          'lan_stable_tag': r['lan_stable_tag'],
        }
    };
  }

  Future<List<String>> listPeerIds() async {
    final rows = await _db.rawQuery('''
      SELECT peer_id FROM peers
      UNION
      SELECT DISTINCT peer_id FROM messages
    ''');
    final ids = rows.map((r) => r['peer_id'] as String).toSet().toList();
    ids.sort();
    return ids;
  }

  /// Peers with at least one stored message (for offline chat list).
  Future<List<String>> listPeerIdsWithConversation() async {
    final rows = await _db.rawQuery('''
      SELECT peer_id FROM messages GROUP BY peer_id HAVING COUNT(*) > 0
    ''');
    return [for (final r in rows) r['peer_id'] as String];
  }

  /// All messages for [peerId], oldest first (indexed query).
  Future<List<ChatMessage>> load(String peerId) async {
    return _withLock(peerId, () async {
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'timestamp ASC, is_mine ASC, id ASC',
      );
      return rows.map(_rowToMessage).toList();
    });
  }

  /// Recent [limit] messages for [peerId], oldest first â€” for chat lazy load.
  Future<List<ChatMessage>> loadRecent(String peerId, int limit) async {
    if (limit <= 0) return [];
    return _withLock(peerId, () async {
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'timestamp DESC, is_mine DESC, id DESC',
        limit: limit,
      );
      final list = rows.map(_rowToMessage).toList();
      return list.reversed.toList();
    });
  }

  /// [messageCount] + newest-[take] messages in one lock â€” avoids offset skew if rows are added concurrently.
  Future<({int total, List<ChatMessage> messages})> loadRecentWindow(
    String peerId,
    int take,
  ) async {
    if (take <= 0) {
      final n = await messageCount(peerId);
      return (total: n, messages: <ChatMessage>[]);
    }
    return _withLock(peerId, () async {
      final n = Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM messages WHERE peer_id = ?',
          [peerId],
        ),
      );
      final total = n ?? 0;
      if (total == 0) return (total: 0, messages: <ChatMessage>[]);
      final limit = min(take, total);
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'timestamp DESC, is_mine DESC, id DESC',
        limit: limit,
      );
      final list = rows.map(_rowToMessage).toList();
      return (total: total, messages: list.reversed.toList());
    });
  }

  /// [messageCount] + [loadRange] for the next older slice â€” single lock for consistent paging.
  Future<({int total, List<ChatMessage> older})> loadOlderBatch(
    String peerId,
    int alreadyLoaded,
    int batchSize,
  ) async {
    if (batchSize <= 0) {
      final n = await messageCount(peerId);
      return (total: n, older: <ChatMessage>[]);
    }
    return _withLock(peerId, () async {
      final n = Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM messages WHERE peer_id = ?',
          [peerId],
        ),
      );
      final total = n ?? 0;
      if (total == 0 || alreadyLoaded >= total) {
        return (total: total, older: <ChatMessage>[]);
      }
      final want = min(batchSize, total - alreadyLoaded);
      final offset = total - alreadyLoaded - want;
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'timestamp ASC, is_mine ASC, id ASC',
        offset: offset,
        limit: want,
      );
      return (total: total, older: rows.map(_rowToMessage).toList());
    });
  }

  Future<int> messageCount(String peerId) async {
    final n = Sqflite.firstIntValue(
      await _db.rawQuery(
        'SELECT COUNT(*) FROM messages WHERE peer_id = ?',
        [peerId],
      ),
    );
    return n ?? 0;
  }

  /// Contiguous slice in chronological order (for loading older history by offset).
  /// [offset] is 0-based into the full ascending-sorted list for this peer.
  Future<List<ChatMessage>> loadRange(
    String peerId,
    int offset,
    int limit,
  ) async {
    if (limit <= 0) return [];
    return _withLock(peerId, () async {
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [peerId],
        orderBy: 'timestamp ASC, is_mine ASC, id ASC',
        offset: offset,
        limit: limit,
      );
      return rows.map(_rowToMessage).toList();
    });
  }

  /// Outgoing text rows that may need resend / delivery confirm after reconnect.
  /// Avoids scanning the full history ([load]) when syncing TCP.
  Future<List<ChatMessage>> loadOutboundTextNeedingSync(String peerId) async {
    return _withLock(peerId, () async {
      final rows = await _db.query(
        'messages',
        where: 'peer_id = ? AND is_mine = 1 AND '
            '(attachment_name IS NULL OR attachment_name = ?) AND '
            'delivery IN (?, ?, ?)',
        whereArgs: [
          peerId,
          '',
          MessageDelivery.pending.name,
          MessageDelivery.undelivered.name,
          MessageDelivery.awaitingConfirm.name,
        ],
        orderBy: 'timestamp ASC, is_mine ASC, id ASC',
      );
      return rows.map(_rowToMessage).toList();
    });
  }

  /// Persists [msg]. Optionally updates peer display row when any of
  /// [peerDisplayName] / [peerIp] / [peerTcpPort] hints are provided.
  /// Returns true if a new message row was written (false if [msg.id] already existed).
  Future<bool> add(
    String peerId,
    ChatMessage msg, {
    String? peerDisplayName,
    String? peerIp,
    int? peerTcpPort,
  }) async {
    var inserted = false;
    await _withLock(peerId, () async {
      final existing = await _db.query(
        'messages',
        columns: ['id'],
        where: 'peer_id = ? AND id = ?',
        whereArgs: [peerId, msg.id],
        limit: 1,
      );
      if (existing.isNotEmpty) return;
      await _db.insert('messages', _messageToRow(peerId, msg));
      inserted = true;
    });

    if (inserted) messageHistoryRevision.value++;

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
    return inserted;
  }

  Future<void> markPendingOutgoingAsUndelivered(String peerId) async {
    await _withLock(peerId, () async {
      final n = await _db.rawUpdate(
        '''
        UPDATE messages SET delivery = ?
        WHERE peer_id = ? AND is_mine = 1
          AND delivery IN (?, ?)
        ''',
        [
          MessageDelivery.undelivered.name,
          peerId,
          MessageDelivery.pending.name,
          MessageDelivery.awaitingConfirm.name,
        ],
      );
      if (n > 0) messageHistoryRevision.value++;
    });
  }

  Future<void> updateDeliveryState(
    String peerId,
    String messageId,
    MessageDelivery delivery,
  ) async {
    await _withLock(peerId, () async {
      await _db.update(
        'messages',
        {'delivery': delivery.name},
        where: 'peer_id = ? AND id = ?',
        whereArgs: [peerId, messageId],
      );
    });
    messageHistoryRevision.value++;
  }

  Future<void> updateAttachmentPath(
      String peerId, String messageId, String path) async {
    return _withLock(peerId, () async {
      await _db.update(
        'messages',
        {'attachment_path': path},
        where: 'peer_id = ? AND id = ?',
        whereArgs: [peerId, messageId],
      );
    });
  }


  Future<void> updateOutboundAttachment(
    String peerId,
    String messageId, {
    String? path,
    int? size,
  }) async {
    await _withLock(peerId, () async {
      final map = <String, Object?>{};
      if (path != null) map['attachment_path'] = path;
      if (size != null) map['attachment_size'] = size;
      if (map.isEmpty) return;
      await _db.update(
        'messages',
        map,
        where: 'peer_id = ? AND id = ?',
        whereArgs: [peerId, messageId],
      );
    });
    messageHistoryRevision.value++;
  }

  Future<void> updateTransferDismissed(
      String peerId, String messageId) async {
    return _withLock(peerId, () async {
      await _db.update(
        'messages',
        {'transfer_dismissed': 1},
        where: 'peer_id = ? AND id = ?',
        whereArgs: [peerId, messageId],
      );
    });
  }

  Future<void> clear(String peerId) async {
    return _withLock(peerId, () async {
      await _db.delete('messages', where: 'peer_id = ?', whereArgs: [peerId]);
      _notifyHistoryCleared(all: false, peerId: peerId);
    });
  }

  Future<void> clearAll() async {
    await _db.delete('messages');
    await _db.delete('peers');
    _notifyHistoryCleared(all: true);
  }

  Future<void> removePeerInfo(String peerId) async {
    await _db.delete('peers', where: 'peer_id = ?', whereArgs: [peerId]);
  }
}

