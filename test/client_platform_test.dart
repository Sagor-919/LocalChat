import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/client_platform.dart';

void main() {
  test('peerReceivesFolderAsFiles', () {
    expect(peerReceivesFolderAsFiles('windows'), isTrue);
    expect(peerReceivesFolderAsFiles('linux'), isTrue);
    expect(peerReceivesFolderAsFiles('macos'), isTrue);
    expect(peerReceivesFolderAsFiles('android'), isFalse);
    expect(peerReceivesFolderAsFiles('ios'), isFalse);
    expect(peerReceivesFolderAsFiles(null), isFalse);
  });
}
