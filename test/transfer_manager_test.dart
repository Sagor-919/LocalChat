import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/transfer_manager.dart';

void main() {
  test('TransferState tracks user pause flag', () {
    final t = TransferState(
      fileId: 'f1',
      peerId: 'p1',
      fileName: 'a.bin',
      totalBytes: 100,
      isSending: true,
    );
    expect(t.userPaused, isFalse);
    t.userPaused = true;
    expect(t.userPaused, isTrue);
  });
}
