import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/chat_message_ordering.dart';
import 'package:local_chat/message_model.dart';

ChatMessage _m({
  required String id,
  required int ts,
  required bool mine,
}) {
  return ChatMessage(
    id: id,
    senderId: mine ? 'me' : 'them',
    text: '',
    timestamp: ts,
    isMine: mine,
  );
}

void main() {
  group('compareChatMessagesChronological', () {
    test('orders by timestamp ascending', () {
      final a = _m(id: 'a', ts: 100, mine: false);
      final b = _m(id: 'b', ts: 200, mine: false);
      expect(compareChatMessagesChronological(a, b), lessThan(0));
      expect(compareChatMessagesChronological(b, a), greaterThan(0));
    });

    test('same timestamp: incoming before outgoing', () {
      final incoming = _m(id: 'z-last-uuid', ts: 1000, mine: false);
      final outgoing = _m(id: 'a-first-uuid', ts: 1000, mine: true);
      expect(compareChatMessagesChronological(incoming, outgoing), lessThan(0));
      expect(compareChatMessagesChronological(outgoing, incoming), greaterThan(0));
    });

    test('same timestamp and isMine: stable id order', () {
      final a = _m(id: 'aaa', ts: 500, mine: true);
      final b = _m(id: 'bbb', ts: 500, mine: true);
      expect(compareChatMessagesChronological(a, b), lessThan(0));
      expect(compareChatMessagesChronological(b, a), greaterThan(0));
    });

    test('equal messages compare equal', () {
      final a = _m(id: 'x', ts: 1, mine: false);
      final b = _m(id: 'x', ts: 1, mine: false);
      expect(compareChatMessagesChronological(a, b), 0);
    });
  });
}
