import 'message_model.dart';

/// In-memory snapshot so returning to the same chat can skip SQLite when nothing changed.
class ChatSessionSnapshot {
  final List<ChatMessage> allMessages;
  final int totalInDb;
  final int displayCount;
  final bool hasMoreOlder;

  ChatSessionSnapshot({
    required List<ChatMessage> allMessages,
    required this.totalInDb,
    required this.displayCount,
    required this.hasMoreOlder,
  }) : allMessages = List<ChatMessage>.from(allMessages);
}

/// Short-lived cache: [save] on chat dispose, [take] on next open for same peer.
class ChatSessionCache {
  ChatSessionCache._();

  static final Map<String, ChatSessionSnapshot> _snapshots = {};

  static void save(String peerId, ChatSessionSnapshot snapshot) {
    _snapshots[peerId] = snapshot;
  }

  /// Removes and returns the snapshot if present (single-use per reopen).
  static ChatSessionSnapshot? take(String peerId) => _snapshots.remove(peerId);

  static void invalidate(String peerId) {
    _snapshots.remove(peerId);
  }
}
