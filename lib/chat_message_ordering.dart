import 'message_model.dart';

/// Chronological list order for chat: ascending time, then at equal milliseconds
/// incoming (![ChatMessage.isMine]) before outgoing so replies always follow the
/// peer line; then stable [ChatMessage.id] tie-break.
int compareChatMessagesChronological(ChatMessage a, ChatMessage b) {
  final c = a.timestamp.compareTo(b.timestamp);
  if (c != 0) return c;
  if (a.isMine && !b.isMine) return 1;
  if (!a.isMine && b.isMine) return -1;
  return a.id.compareTo(b.id);
}
