import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/file_transfer_crypto.dart';

void main() {
  test('encrypt/decrypt chunk round trip', () async {
    const a = 'peer-a';
    const b = 'peer-b';
    const fileId = 'file-1';
    final key = await FileTransferCrypto.secretKey(a, b, fileId);
    const plain = [1, 2, 3, 4, 5, 6, 7, 8];
    final enc = await FileTransferCrypto.encryptChunk(key, 0, plain);
    final dec = await FileTransferCrypto.decryptChunk(key, 0, enc);
    expect(dec, plain);
  });
}
