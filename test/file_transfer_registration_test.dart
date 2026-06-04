import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/file_transfer_auth.dart';

void main() {
  test('token requires registered peer pair', () {
    const a = 'peer-a';
    const b = 'peer-b';
    const fileId = 'file-1';
    final token = FileTransferAuth.token(a, b, fileId);
    expect(FileTransferAuth.verify(a, b, fileId, token), isTrue);
    expect(FileTransferAuth.verify(a, b, fileId, 'bad'), isFalse);
    expect(FileTransferAuth.verify(a, 'other', fileId, token), isFalse);
  });
}
