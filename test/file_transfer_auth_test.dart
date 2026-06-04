import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/file_transfer_auth.dart';

void main() {
  const a = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const b = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  const fileId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

  test('token is symmetric for peer order', () {
    final t1 = FileTransferAuth.token(a, b, fileId);
    final t2 = FileTransferAuth.token(b, a, fileId);
    expect(t1, t2);
    expect(t1.length, 64);
  });

  test('verify accepts matching token', () {
    final t = FileTransferAuth.token(a, b, fileId);
    expect(FileTransferAuth.verify(a, b, fileId, t), isTrue);
    expect(FileTransferAuth.verify(b, a, fileId, t), isTrue);
  });

  test('verify rejects wrong token or file id', () {
    final t = FileTransferAuth.token(a, b, fileId);
    expect(FileTransferAuth.verify(a, b, fileId, 'deadbeef'), isFalse);
    expect(FileTransferAuth.verify(a, b, 'other-id', t), isFalse);
    expect(FileTransferAuth.verify(a, b, fileId, null), isFalse);
  });
}
